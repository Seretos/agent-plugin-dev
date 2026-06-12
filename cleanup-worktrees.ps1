#requires -Version 5.1
<#
.SYNOPSIS
    Walks every project in this meta-repo, finds its git worktrees, and removes
    the ones that hold no work that could be lost.

.DESCRIPTION
    The same set of repositories that start-sessions.ps1 launches sessions for is
    scanned: every immediate subdirectory of libs/, plugins/, extensions/ and
    apps/, plus the meta-repo root, the MCP test sandbox (mcp-test) and the
    marketplace repo (agent-marketplace). Repositories are discovered dynamically, so adding or
    removing a project folder is reflected automatically.

    For each repository the linked worktrees reported by 'git worktree list' are
    examined (the primary worktree - the repo checkout itself - is never touched).
    Worktrees created both by the worktree plugin (under
    %USERPROFILE%\agent-worktree-store\) and by Claude Code itself (under
    .claude\worktrees\) are covered, because both are registered git worktrees.

    A worktree is considered SAFE to remove only when nothing in it could be lost:

      * the working tree is clean - no staged, unstaged or untracked changes, and
      * its branch has no commits that are absent from the repository's default
        branch (origin/HEAD, falling back to main/master). Commits that exist
        nowhere else would be lost on removal, so such a worktree is kept.

    Detached-HEAD worktrees and worktrees whose unique-commit status cannot be
    determined are treated as unsafe and kept (unless -Force).

    With -Force every worktree is removed regardless of its contents - uncommitted
    changes and unmerged commits included. Locked worktrees (e.g. Claude Code's
    own .claude\worktrees entries) are only removable with -Force.

    Nothing is removed in -WhatIf / dry-run mode; pass nothing to act for real.

.PARAMETER Force
    Remove every worktree even when doing so discards uncommitted changes or
    unmerged commits. Also unlocks and removes locked worktrees.

.PARAMETER WhatIf
    Report what would be removed (and why each kept worktree is kept) without
    removing anything.
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot

# --- Discover the repositories to scan (mirrors start-sessions.ps1) ------------

$repos = New-Object System.Collections.Generic.List[string]

foreach ($parent in @((Join-Path $root 'libs'), (Join-Path $root 'plugins'), (Join-Path $root 'extensions'), (Join-Path $root 'apps'))) {
    if (Test-Path -LiteralPath $parent) {
        Get-ChildItem -Path $parent -Directory | ForEach-Object { $repos.Add($_.FullName) }
    } else {
        Write-Warning "Skipping missing directory: $parent"
    }
}

# The meta-repo root plus the two standalone sibling repos.
$repos.Add($root)
foreach ($extra in @((Join-Path $root 'mcp-test'), (Join-Path $root 'agent-marketplace'))) {
    if (Test-Path -LiteralPath $extra) { $repos.Add($extra) }
}

# --- Helpers ------------------------------------------------------------------

# Run a git command in a repo and return its stdout lines. stderr is discarded and
# the error preference is relaxed locally: under PowerShell 5.1 a native command's
# stderr is wrapped into ErrorRecords, which would otherwise terminate the script
# (e.g. when git reports a stale worktree whose directory is gone). Callers decide
# what a non-zero ExitCode means.
function Invoke-Git {
    param([string]$RepoPath, [string[]]$GitArgs)
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $RepoPath @GitArgs 2>$null
    } finally {
        $ErrorActionPreference = $eap
    }
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}

# Parse 'git worktree list --porcelain' into objects. The first record is always
# the primary worktree (the repo checkout itself); linked worktrees follow.
function Get-Worktrees {
    param([string]$RepoPath)

    $res = Invoke-Git $RepoPath @('worktree', 'list', '--porcelain')
    if ($res.ExitCode -ne 0) { return @() }

    $worktrees = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in $res.Output) {
        if ($line -like 'worktree *') {
            if ($null -ne $current) { $worktrees.Add([PSCustomObject]$current) }
            $current = @{ Path = $line.Substring(9); Head = $null; Branch = $null; Detached = $false; Locked = $false }
        } elseif ($line -like 'HEAD *') {
            $current.Head = $line.Substring(5)
        } elseif ($line -like 'branch *') {
            $current.Branch = $line.Substring(7)  # e.g. refs/heads/fix/12-foo
        } elseif ($line -eq 'detached') {
            $current.Detached = $true
        } elseif ($line -eq 'locked' -or $line -like 'locked *') {
            $current.Locked = $true
        }
    }
    if ($null -ne $current) { $worktrees.Add([PSCustomObject]$current) }
    return $worktrees
}

# Resolve the ref to compare worktree branches against: origin/HEAD if known,
# otherwise main, otherwise master. Returns $null if none can be found.
function Get-BaseRef {
    param([string]$RepoPath)

    $res = Invoke-Git $RepoPath @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    if ($res.ExitCode -eq 0 -and $res.Output) { return ($res.Output | Select-Object -First 1) }

    foreach ($candidate in @('main', 'master')) {
        $v = Invoke-Git $RepoPath @('rev-parse', '--verify', '--quiet', "refs/heads/$candidate")
        if ($v.ExitCode -eq 0 -and $v.Output) { return $candidate }
    }
    return $null
}

# Decide whether a linked worktree is safe to remove (clean tree + no unique
# commits). Returns @{ Safe = bool; Reason = string }.
function Test-WorktreeSafe {
    param([string]$RepoPath, [object]$Worktree, [string]$BaseRef)

    # The directory is already gone - only a stale admin entry remains, nothing to
    # lose. Cleaning it up is exactly what we want.
    if (-not (Test-Path -LiteralPath $Worktree.Path)) {
        return @{ Safe = $true; Reason = 'directory already gone (stale entry)' }
    }

    # A locked worktree whose directory still exists is treated as in use (e.g. an
    # active Claude Code session). Keep it unless -Force is given.
    if ($Worktree.Locked) {
        return @{ Safe = $false; Reason = 'locked (in use) - use -Force' }
    }

    $dirty = Invoke-Git $Worktree.Path @('status', '--porcelain')
    if ($dirty.ExitCode -ne 0) {
        return @{ Safe = $false; Reason = 'cannot read status' }
    }
    if (@($dirty.Output | Where-Object { $_ -ne '' }).Count -gt 0) {
        return @{ Safe = $false; Reason = 'uncommitted/untracked changes' }
    }

    if ($Worktree.Detached) {
        return @{ Safe = $false; Reason = 'detached HEAD' }
    }
    if (-not $BaseRef) {
        return @{ Safe = $false; Reason = 'no base branch to compare against' }
    }

    # Commits reachable from the worktree HEAD but not from the base ref. Any such
    # commit would be lost on removal.
    $unique = Invoke-Git $RepoPath @('rev-list', '--count', "$BaseRef..$($Worktree.Head)")
    if ($unique.ExitCode -ne 0) {
        return @{ Safe = $false; Reason = 'cannot compare against base branch' }
    }
    $count = 0
    [void][int]::TryParse(($unique.Output | Select-Object -First 1), [ref]$count)
    if ($count -gt 0) {
        return @{ Safe = $false; Reason = "$count unmerged commit(s) vs $BaseRef" }
    }

    return @{ Safe = $true; Reason = 'clean and fully merged' }
}

# --- Scan and clean -----------------------------------------------------------

$removed = 0
$kept = 0
$failed = 0

foreach ($repo in $repos) {
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { continue }

    $worktrees = @(Get-Worktrees $repo)
    if ($worktrees.Count -le 1) { continue }   # only the primary worktree

    $linked = $worktrees | Select-Object -Skip 1   # drop the primary checkout
    if ($linked.Count -eq 0) { continue }

    Write-Host ''
    Write-Host ("=== {0} ===" -f (Split-Path -Leaf $repo)) -ForegroundColor Cyan

    $baseRef = Get-BaseRef $repo

    foreach ($wt in $linked) {
        $label = if ($wt.Branch) { $wt.Branch -replace '^refs/heads/', '' } else { '(detached)' }

        if ($Force) {
            $verdict = @{ Safe = $true; Reason = 'forced' }
        } else {
            $verdict = Test-WorktreeSafe $repo $wt $baseRef
        }

        if (-not $verdict.Safe) {
            Write-Host ("  KEEP   {0}  [{1}]" -f $label, $verdict.Reason) -ForegroundColor Yellow
            $kept++
            continue
        }

        if ($WhatIf) {
            Write-Host ("  WOULD REMOVE  {0}  ({1})" -f $label, $verdict.Reason) -ForegroundColor Green
            $removed++
            continue
        }

        $rm = Invoke-Git $repo @('worktree', 'remove', $wt.Path)

        # We only reach here when the verdict is Safe, i.e. nothing can be lost
        # (clean + merged, a stale entry, or -Force). So escalating is fine: unlock
        # and force-remove, then fall back to prune for entries whose directory is
        # already gone (a plain remove cannot delete those).
        if ($rm.ExitCode -ne 0) {
            Invoke-Git $repo @('worktree', 'unlock', $wt.Path) | Out-Null
            $rm = Invoke-Git $repo @('worktree', 'remove', '--force', $wt.Path)
            if ($rm.ExitCode -ne 0) {
                Invoke-Git $repo @('worktree', 'prune') | Out-Null
                if (-not (Test-Path -LiteralPath $wt.Path)) { $rm.ExitCode = 0 }
            }
        }

        if ($rm.ExitCode -eq 0) {
            Write-Host ("  REMOVED  {0}  ({1})" -f $label, $verdict.Reason) -ForegroundColor Green
            $removed++
        } else {
            Write-Host ("  FAILED   {0}  - git worktree remove exited {1}" -f $label, $rm.ExitCode) -ForegroundColor Red
            $failed++
        }
    }

    # Drop administrative entries for worktree directories that are already gone.
    Invoke-Git $repo @('worktree', 'prune') | Out-Null
}

Write-Host ''
$summaryVerb = if ($WhatIf) { 'would remove' } else { 'removed' }
Write-Host ("Done: {0} {1}, {2} kept, {3} failed." -f $removed, $summaryVerb, $kept, $failed) -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 }
