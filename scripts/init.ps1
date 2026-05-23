#requires -Version 5.1
<#
.SYNOPSIS
  Bootstraps the agent-plugin-dev workspace.

.DESCRIPTION
  - Clones each repo listed in ../workspace.json (skips repos that are already present).
  - Creates the mcp-test/ symlinks that point back to the real plugin repos.
  - If symlink creation fails (no Developer Mode and no admin rights), prints
    the New-Item commands so the user can run them from an elevated shell.

  Idempotent: safe to run multiple times.
#>

$ErrorActionPreference = 'Stop'

$repoRoot     = Resolve-Path (Join-Path $PSScriptRoot '..')
$manifestPath = Join-Path $repoRoot 'workspace.json'

if (-not (Test-Path $manifestPath)) {
    Write-Host "[error] workspace.json not found at $manifestPath" -ForegroundColor Red
    exit 1
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

Write-Host ""
Write-Host "=== Cloning sub-repos ===" -ForegroundColor Cyan

foreach ($repo in $manifest.repos) {
    $target = Join-Path $repoRoot $repo.path
    if (Test-Path (Join-Path $target '.git')) {
        Write-Host "  [skip] $($repo.name) already present at $($repo.path)"
        continue
    }
    if ((Test-Path $target) -and (Get-ChildItem $target -Force | Measure-Object).Count -gt 0) {
        Write-Host "  [warn] $($repo.path) exists and is not empty but has no .git - skipping" -ForegroundColor Yellow
        continue
    }

    Write-Host "  [clone] $($repo.name) <- $($repo.remote)"
    & git clone --branch $repo.branch $repo.remote $target
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [error] git clone failed for $($repo.name)" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "=== Creating mcp-test symlinks ===" -ForegroundColor Cyan

$failedLinks = @()

foreach ($link in $manifest.mcpTestSymlinks) {
    $linkPath   = Join-Path $repoRoot $link.from
    $targetPath = Join-Path $repoRoot $link.to

    if (Test-Path $linkPath) {
        Write-Host "  [skip] $($link.from) already exists"
        continue
    }
    if (-not (Test-Path $targetPath)) {
        Write-Host "  [warn] target $($link.to) does not exist yet - skipping" -ForegroundColor Yellow
        continue
    }

    $parent = Split-Path $linkPath -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    try {
        $resolvedTarget = (Resolve-Path $targetPath).Path
        New-Item -ItemType SymbolicLink -Path $linkPath -Target $resolvedTarget -ErrorAction Stop | Out-Null
        Write-Host "  [link] $($link.from) -> $($link.to)"
    }
    catch {
        Write-Host "  [fail] $($link.from)" -ForegroundColor Yellow
        $failedLinks += [PSCustomObject]@{
            From   = $linkPath
            Target = (Resolve-Path $targetPath).Path
        }
    }
}

if ($failedLinks.Count -gt 0) {
    Write-Host ""
    Write-Host "[warn] Could not create $($failedLinks.Count) symlink(s) - missing permission." -ForegroundColor Yellow
    Write-Host "       Run these commands from an elevated (Admin) PowerShell:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($f in $failedLinks) {
        Write-Host "  New-Item -ItemType SymbolicLink -Path `"$($f.From)`" -Target `"$($f.Target)`"" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "       Alternative: enable Developer Mode under Settings > For developers." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
