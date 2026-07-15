#requires -Version 5.1
<#
.SYNOPSIS
    Updates the plugin marketplaces and all installed plugins, then starts a
    background Claude session for every project under libs/, plugins/,
    extensions/ and apps/.

.DESCRIPTION
    Runs in three phases:

    1. Guard - refuses to run while any Claude Code CLI session is open. Updating
       a plugin that is in use by another session currently fails in Claude Code
       (the scope does not matter), so every session must be closed first. The
       Claude *desktop* app (under \WindowsApps\) is ignored - only the CLI build
       counts. The guard only applies when the update phase will run: with
       -NoUpdate there is nothing to conflict with, so the launch proceeds even
       while other sessions are open. Override with -Force.

    2. Update (default on) - refreshes the marketplace source(s), then updates
       each installed plugin in the exact directory and scope where it is
       installed, driven by the install ledger at
       ~/.claude/plugins/installed_plugins.json. Because the 'project' and 'local'
       scopes are per-directory, each update runs with that directory as the
       working directory; only 'user' scope is global. This never creates a new
       install where one does not already exist. Only user-global plugins and
       install records inside this repo are touched. This runs by DEFAULT - the
       whole point of the script is that you never forget to update again. Pass
       -NoUpdate to skip it, or -Marketplace to narrow it to a single marketplace.

    3. Launch - discovers each immediate subdirectory of libs/, plugins/,
       extensions/ and apps/ and launches a Claude session in that directory
       with:

           claude --allow-dangerously-skip-permissions --verbose --rc "<project-name>" --bg --permission-mode "bypassPermissions"

       Launches are SERIALIZED, not fired in parallel. Every Claude process does
       a read-modify-write of the global ~/.claude.json during startup, and that
       file has no locking. Starting ~18 sessions within milliseconds (the
       previous behaviour) let those writes overlap and produced truncated /
       invalid JSON in ~/.claude.json. To avoid the race, this script launches
       one session at a time and waits until ~/.claude.json has settled - the
       just-started process has written and the file is valid JSON again - before
       launching the next. A backup of ~/.claude.json is taken before the burst
       and the file is checked for validity up front as a safety net.

    Projects are discovered dynamically, so adding or removing a project folder
    is reflected automatically on the next run. A session for the meta-repo root
    itself (agent-plugin-dev), one for the MCP test sandbox (mcp-test) and one
    for the marketplace repo (agent-marketplace) are launched in addition to the
    discovered projects.

.PARAMETER NoUpdate
    Skip the marketplace/plugin update phase and only launch the sessions. The
    running-session guard is also skipped, so launches proceed even while other
    Claude Code sessions are open.

.PARAMETER NoLaunch
    Skip phase 3 and only run the marketplace/plugin update - no sessions are
    started. Combine with -Marketplace to update just one marketplace's plugins
    without starting anything.

.PARAMETER Marketplace
    Limit the update phase to plugins from a single marketplace (e.g.
    'agent-marketplace'). Defaults to '*' (every marketplace).

.PARAMETER Force
    Launch even if other Claude Code CLI sessions are already running. Note: the
    update phase may fail for plugins that are in use by those sessions.
#>

[CmdletBinding()]
param(
    [string]$Marketplace = '*',
    [switch]$NoUpdate,
    [switch]$NoLaunch,
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

# The guard only matters when the update phase will actually run - a running
# session only blocks plugin updates, not the launch itself. With -NoUpdate
# there is nothing to conflict with, so skip the check entirely.
if (-not $NoUpdate -and $running.Count -gt 0 -and -not $Force) {
    Write-Host ''
    Write-Host "Aborting: $($running.Count) Claude Code session(s) are still running." -ForegroundColor Red
    Write-Host "Plugins cannot be updated while they are in use by another session." -ForegroundColor Red
    Write-Host "Close the sessions below and re-run this script (or pass -NoUpdate / -Force to skip this check):" -ForegroundColor Red
    foreach ($proc in $running) {
        Write-Host ("  PID {0}  {1}" -f $proc.Id, $proc.Path)
    }
    Write-Host ''
    exit 1
}

if (-not $NoUpdate -and $running.Count -gt 0) {
    Write-Warning "$($running.Count) Claude Code session(s) running - continuing anyway because -Force was given. Plugin updates may fail."
}

# --- Phase 2: update marketplaces and installed plugins (default on) ----------

if (-not $NoUpdate) {
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
    Write-Host 'Skipping marketplace/plugin update (-NoUpdate was given).' -ForegroundColor Yellow
}

# --- Phase 3: launch a background session per project -------------------------
#
# Launches are serialized to protect the global ~/.claude.json. Each starting
# Claude process read-modify-writes that file during startup, and it has no
# locking - firing every session at once let those writes collide and corrupted
# the JSON. See Wait-ClaudeConfigSettled / Start-ClaudeSession below.

if ($NoLaunch) {
    Write-Host 'Skipping session launch (-NoLaunch was given).' -ForegroundColor Yellow
    return
}

$configPath = Join-Path $env:USERPROFILE '.claude.json'

# Returns $true only if $Path exists and parses as JSON. Test-Json does not exist
# on Windows PowerShell 5.1, so validate via ConvertFrom-Json in a try/catch.
function Test-ValidJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $null = $raw | ConvertFrom-Json -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# Block until the just-launched session has finished mutating ~/.claude.json:
# wait for a write newer than $Since, then for the file to be valid JSON and
# quiet (no further write) for $QuietMs. Returns $false on timeout so the caller
# can warn and continue rather than hang forever.
function Wait-ClaudeConfigSettled {
    param(
        [string]$Path,
        [datetime]$Since,
        [int]$TimeoutSec = 25,
        [int]$QuietMs = 800
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $sawNewWrite = $false
    $quietStart = $null
    $lastSeen = $Since
    while ((Get-Date) -lt $deadline) {
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item) {
            $mtime = $item.LastWriteTimeUtc
            if ($mtime -gt $lastSeen) {
                # Fresh write activity from the new process - (re)start the quiet timer.
                $sawNewWrite = $true
                $lastSeen = $mtime
                $quietStart = $null
            } elseif ($sawNewWrite) {
                if (Test-ValidJson -Path $Path) {
                    if ($null -eq $quietStart) { $quietStart = Get-Date }
                    if (((Get-Date) - $quietStart).TotalMilliseconds -ge $QuietMs) {
                        return $true
                    }
                } else {
                    # Mid-write / transient invalid - keep waiting for it to close.
                    $quietStart = $null
                }
            }
        }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

# Launch a single background session and wait for the config to settle before
# returning, so the next launch never overlaps this one's startup write.
function Start-ClaudeSession {
    param([string]$Project, [string]$Path)

    Write-Host "Starting Claude session for '$Project' in $Path"
    $arguments = @(
        '--allow-dangerously-skip-permissions',
        '--verbose',
        '--name', $Project,
        '--rc', $Project,
        '--bg',
        '--permission-mode', 'bypassPermissions'
    )

    $since = if (Test-Path -LiteralPath $configPath) {
        (Get-Item -LiteralPath $configPath).LastWriteTimeUtc
    } else {
        [datetime]::MinValue
    }

    Start-Process -FilePath 'claude' -ArgumentList $arguments -WorkingDirectory $Path

    if (-not (Wait-ClaudeConfigSettled -Path $configPath -Since $since)) {
        Write-Warning ("Config did not settle within timeout after '{0}'. Continuing, but ~/.claude.json may be under concurrent write." -f $Project)
    }
}

# Safety net: validate ~/.claude.json before the launch burst and back it up, so
# a slip-through corruption is both detected early and recoverable.
if (Test-Path -LiteralPath $configPath) {
    if (Test-ValidJson -Path $configPath) {
        Copy-Item -LiteralPath $configPath -Destination "$configPath.bak" -Force
        Write-Host "Backed up ~/.claude.json to $configPath.bak" -ForegroundColor DarkGray
    } else {
        Write-Warning "~/.claude.json is ALREADY invalid JSON before launching. Restore it first (a previous backup may exist at $configPath.bak)."
    }
}

# Collect every target directory, then launch them one at a time.
$targets = New-Object System.Collections.Generic.List[object]

$parents = @(
    (Join-Path $root 'libs'),
    (Join-Path $root 'plugins'),
    (Join-Path $root 'extensions'),
    (Join-Path $root 'apps')
)
foreach ($parent in $parents) {
    if (-not (Test-Path $parent)) {
        Write-Warning "Skipping missing directory: $parent"
        continue
    }
    Get-ChildItem -Path $parent -Directory | ForEach-Object {
        $targets.Add([PSCustomObject]@{ Project = $_.Name; Path = $_.FullName })
    }
}

# The meta-repo root itself (agent-plugin-dev).
$targets.Add([PSCustomObject]@{ Project = 'agent-plugin-dev'; Path = $root })

# The MCP test sandbox (mcp-test) and the marketplace repo (agent-marketplace).
foreach ($extra in @('mcp-test', 'agent-marketplace')) {
    $extraPath = Join-Path $root $extra
    if (Test-Path $extraPath) {
        $targets.Add([PSCustomObject]@{ Project = $extra; Path = $extraPath })
    } else {
        Write-Warning "Skipping missing directory: $extraPath"
    }
}

foreach ($t in $targets) {
    Start-ClaudeSession -Project $t.Project -Path $t.Path
}
