#requires -Version 5.1
<#
.SYNOPSIS
    Starts a background Claude session for every project under libs/, plugins/ and apps/.
    Optionally updates the plugin marketplaces and refreshes all installed plugins
    first, but only when -Update (or -Marketplace) is given.

.DESCRIPTION
    Runs in three phases:

    1. Guard - refuses to run while any Claude Code CLI session is open. Updating
       a plugin that is in use by another session currently fails in Claude Code
       (the scope does not matter), so every session must be closed first. The
       Claude *desktop* app (under \WindowsApps\) is ignored - only the CLI build
       counts. Override with -Force.

    2. Update (opt-in) - skipped by default. Pass -Update (or -Marketplace) to
       run it. Refreshes the marketplace source(s), then updates each installed
       plugin in the exact directory and scope where it is installed, driven by
       the install ledger at ~/.claude/plugins/installed_plugins.json. Because the
       'project' and 'local' scopes are per-directory, each update runs with that
       directory as the working directory; only 'user' scope is global. This never
       creates a new install where one does not already exist. Only user-global
       plugins and install records inside this repo are touched. Narrow it to one
       marketplace with -Marketplace.

    3. Launch - discovers each immediate subdirectory of libs/, plugins/ and
       apps/ and launches a Claude session in that directory with:

           claude --allow-dangerously-skip-permissions --verbose --rc "<project-name>" --bg --permission-mode "bypassPermissions"

    Projects are discovered dynamically, so adding or removing a project folder
    is reflected automatically on the next run. A session for the meta-repo root
    itself (agent-plugin-dev), one for the MCP test sandbox (mcp-test) and one
    for the marketplace repo (agent-marketplace) are launched in addition to the
    discovered projects.

.PARAMETER Update
    Run the marketplace/plugin update phase before launching sessions. Without
    this switch (and without -Marketplace) the update phase is skipped and the
    script only launches sessions.

.PARAMETER Marketplace
    Limit the update phase to plugins from a single marketplace (e.g.
    'agent-marketplace'). Passing this implies -Update. Defaults to '*' (every
    marketplace) when -Update is given.

.PARAMETER Force
    Launch even if other Claude Code CLI sessions are already running. Note: the
    update phase may fail for plugins that are in use by those sessions.
#>

[CmdletBinding()]
param(
    [string]$Marketplace = '*',
    [switch]$Update,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot

# --- Phase 1: guard against already-running Claude Code CLI sessions ----------

# Match the 'claude' CLI process while excluding the packaged desktop app, which
# lives under \WindowsApps\ and is unrelated to Claude Code sessions.
$running = @(
    Get-Process -Name 'claude' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and ($_.Path -notlike '*\WindowsApps\*') }
)

if ($running.Count -gt 0 -and -not $Force) {
    Write-Host ''
    Write-Host "Aborting: $($running.Count) Claude Code session(s) are still running." -ForegroundColor Red
    Write-Host "Plugins cannot be updated while they are in use by another session." -ForegroundColor Red
    Write-Host "Close the sessions below and re-run this script (or pass -Force to skip this check):" -ForegroundColor Red
    foreach ($proc in $running) {
        Write-Host ("  PID {0}  {1}" -f $proc.Id, $proc.Path)
    }
    Write-Host ''
    exit 1
}

if ($running.Count -gt 0) {
    Write-Warning "$($running.Count) Claude Code session(s) running - continuing anyway because -Force was given. Plugin updates may fail."
}

# --- Phase 2: update marketplaces and installed plugins (opt-in) --------------

# Update is opt-in: it runs only when -Update is given, or when -Marketplace
# narrows it to a specific marketplace (which implies the intent to update).
$doUpdate = $Update -or ($Marketplace -ne '*')

if ($doUpdate) {
    # 2a. Refresh the marketplace source(s) so newer plugin versions are visible.
    if ($Marketplace -eq '*') {
        Write-Host 'Refreshing all configured marketplaces...' -ForegroundColor Cyan
        & claude plugin marketplace update
    } else {
        Write-Host "Refreshing marketplace '$Marketplace'..." -ForegroundColor Cyan
        & claude plugin marketplace update $Marketplace
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Marketplace update exited with code $LASTEXITCODE"
    }

    # 2b. Update each installed plugin in the exact directory and scope where it
    #     is installed. The 'project' and 'local' scopes are per-directory, so the
    #     update only takes effect when run with that directory as the working
    #     directory - running everything from the repo root (the previous bug)
    #     updated a single record and left every other project on the old version.
    #     The install ledger below is the authoritative per-path/per-scope record.
    $store = Join-Path $env:USERPROFILE '.claude\plugins\installed_plugins.json'
    if (-not (Test-Path -LiteralPath $store)) {
        Write-Warning "Plugin install ledger not found at $store - skipping plugin updates."
    } else {
        $data = Get-Content -LiteralPath $store -Raw | ConvertFrom-Json

        # Restrict to user-global plugins plus install records inside this repo;
        # unrelated projects/worktrees elsewhere on disk are left untouched.
        $rootPrefix = $root.TrimEnd('\') + '\'
        $records = New-Object System.Collections.Generic.List[object]
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($prop in $data.plugins.PSObject.Properties) {
            $id = $prop.Name
            if ($Marketplace -ne '*' -and -not $id.EndsWith("@$Marketplace")) { continue }
            foreach ($rec in @($prop.Value)) {
                $scope = $rec.scope
                $path = $rec.projectPath
                if ($scope -ne 'user') {
                    if (-not $path) { continue }
                    $inRepo = ($path -ieq $root) -or `
                        $path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
                    if (-not $inRepo) { continue }
                }
                if ($seen.Add("$id|$scope|$path")) {
                    $records.Add([PSCustomObject]@{ Id = $id; Scope = $scope; Path = $path })
                }
            }
        }

        if ($records.Count -eq 0) {
            Write-Warning 'No matching installed plugins found to update.'
        } else {
            Write-Host "Updating $($records.Count) plugin install(s)..." -ForegroundColor Cyan
            foreach ($r in $records) {
                $where = if ($r.Scope -eq 'user') { $root } else { $r.Path }
                if (-not (Test-Path -LiteralPath $where)) {
                    Write-Warning ("skip {0} [{1}] - directory missing: {2}" -f $r.Id, $r.Scope, $where)
                    continue
                }
                Write-Host ("  {0}  [{1}]  in {2}" -f $r.Id, $r.Scope, $where)
                Push-Location -LiteralPath $where
                try {
                    & claude plugin update $r.Id --scope $r.Scope
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning ("update failed: {0} [{1}] in {2} (exit {3})" -f $r.Id, $r.Scope, $where, $LASTEXITCODE)
                    }
                } finally {
                    Pop-Location
                }
            }
        }
    }
}
else {
    Write-Host 'Skipping marketplace/plugin update (pass -Update to enable).' -ForegroundColor Yellow
}

# --- Phase 3: launch a background session per project -------------------------

$parents = @(
    (Join-Path $root 'libs'),
    (Join-Path $root 'plugins'),
    (Join-Path $root 'apps')
)

foreach ($parent in $parents) {
    if (-not (Test-Path $parent)) {
        Write-Warning "Skipping missing directory: $parent"
        continue
    }

    Get-ChildItem -Path $parent -Directory | ForEach-Object {
        $project = $_.Name
        $projectPath = $_.FullName

        Write-Host "Starting Claude session for '$project' in $projectPath"

        $arguments = @(
            '--allow-dangerously-skip-permissions',
            '--verbose',
            '--rc', $project,
            '--bg',
            '--permission-mode', 'bypassPermissions'
        )

        Start-Process -FilePath 'claude' -ArgumentList $arguments -WorkingDirectory $projectPath
    }
}

# Finally, a session for the meta-repo root itself (agent-plugin-dev).
$rootProject = 'agent-plugin-dev'
Write-Host "Starting Claude session for '$rootProject' in $root"

$rootArguments = @(
    '--allow-dangerously-skip-permissions',
    '--verbose',
    '--rc', $rootProject,
    '--bg',
    '--permission-mode', 'bypassPermissions'
)

Start-Process -FilePath 'claude' -ArgumentList $rootArguments -WorkingDirectory $root

# A session for the MCP test sandbox (mcp-test).
$mcpTestPath = Join-Path $root 'mcp-test'
if (Test-Path $mcpTestPath) {
    $mcpTestProject = 'mcp-test'
    Write-Host "Starting Claude session for '$mcpTestProject' in $mcpTestPath"

    $mcpTestArguments = @(
        '--allow-dangerously-skip-permissions',
        '--verbose',
        '--rc', $mcpTestProject,
        '--bg',
        '--permission-mode', 'bypassPermissions'
    )

    Start-Process -FilePath 'claude' -ArgumentList $mcpTestArguments -WorkingDirectory $mcpTestPath
} else {
    Write-Warning "Skipping missing directory: $mcpTestPath"
}

# A session for the marketplace repo (agent-marketplace).
$marketplacePath = Join-Path $root 'agent-marketplace'
if (Test-Path $marketplacePath) {
    $marketplaceProject = 'agent-marketplace'
    Write-Host "Starting Claude session for '$marketplaceProject' in $marketplacePath"

    $marketplaceArguments = @(
        '--allow-dangerously-skip-permissions',
        '--verbose',
        '--rc', $marketplaceProject,
        '--bg',
        '--permission-mode', 'bypassPermissions'
    )

    Start-Process -FilePath 'claude' -ArgumentList $marketplaceArguments -WorkingDirectory $marketplacePath
} else {
    Write-Warning "Skipping missing directory: $marketplacePath"
}
