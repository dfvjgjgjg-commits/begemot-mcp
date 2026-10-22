# Begemot MCP Uninstaller for OpenCode
# =====================================
# Removes everything the auto-installer puts in place, in the reverse order it
# was installed, and leaves the user's own configuration untouched:
#
#   - stops and deletes the HTTP autostart task, kills the running server
#   - removes OUR entries from opencode.json / opencode.jsonc, textually and
#     surgically: comments, key order, formatting and the user's own servers,
#     instructions and plugins all survive
#   - deletes the prompt, the greenlight plugin and the deployed server tree
#   - keeps the .bak.<timestamp> config backups unless -PurgeBackups
#
# Idempotent: running it on a machine with nothing installed changes nothing.
#
# One-liner:
#   irm https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/uninstall_begemot_opencode.ps1 | iex
#
# With a full purge (also deletes the config backups the installer made):
#   irm https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/uninstall_begemot_opencode.ps1 | iex
#   # or, from a downloaded copy:
#   .\uninstall_begemot_opencode.ps1 -PurgeBackups
# =====================================
param(
    [switch]$PurgeBackups,
    [switch]$KeepServerDir
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --- repository ---
$RepoOwner = "dfvjgjgjg-commits"
$RepoName  = "begemot-mcp"
$Branch    = "main"

# --- paths (identical to the installer) ---
$HomeDir    = $env:USERPROFILE
$McpDir     = Join-Path $HomeDir "Documents\MCP\begemot-mcp"
$ConfigDir  = Join-Path $HomeDir ".config\opencode"
$PromptFile = Join-Path $ConfigDir "begemot_prompt.md"
$PluginDst  = Join-Path $ConfigDir "plugins\greenlight"
$HttpPort   = 8788
$TaskName   = "BegemotMcpHttp"
$ServerName = "begemot-traffic-light"

$STEPS_TOTAL = 5

function Banner {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host "  BEGEMOT MCP - OpenCode Uninstaller" -ForegroundColor Red
    Write-Host "  your own config is left untouched" -ForegroundColor DarkGray
    Write-Host "  ============================================" -ForegroundColor Red
    Write-Host ""
}
function Step($n, $t) { Write-Host ""; Write-Host "[$n/$STEPS_TOTAL] $t" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "  OK: $m" -ForegroundColor Green }
function Skip($m) { Write-Host "  --: $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "  WARN: $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "  ERROR: $m" -ForegroundColor Red }
function Pause() {
    # Same guard as the installer: with a redirected stdin Read-Host blocks
    # forever, which would leave the uninstall running and holding its log.
    try {
        if ([Console]::IsInputRedirected) { return }
        if (-not [Environment]::UserInteractive) { return }
    } catch { return }
    Read-Host "Press Enter to close"
}
function Die($m)  { Err $m; Pause; exit 1 }

Banner

# ============================================================
# [1/5] What is actually installed here
# ============================================================
Step 1 "Looking for an existing install..."

$found = @()
if (Test-Path $McpDir)    { $found += "server tree : $McpDir" }
if (Test-Path $PromptFile){ $found += "prompt      : $PromptFile" }
if (Test-Path $PluginDst) { $found += "plugin      : $PluginDst" }

$taskExists = $false
try { $taskExists = [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) } catch {}
if ($taskExists) { $found += "autostart   : scheduled task '$TaskName'" }

$cfgFiles = @()
foreach ($cf in @("opencode.jsonc", "opencode.json")) {
    $p = Join-Path $ConfigDir $cf
    if (Test-Path $p) {
        $txt = [IO.File]::ReadAllText($p)
        if ($txt -like "*$ServerName*" -or $txt -like "*begemot_prompt*" -or $txt -like "*greenlight*") {
            $cfgFiles += $p
        }
    }
}
if ($cfgFiles.Count) { $found += "config      : " + (($cfgFiles | ForEach-Object { Split-Path $_ -Leaf }) -join ", ") }

if (-not $found.Count) {
    Skip "nothing of Begemot is installed - nothing to remove"
    Write-Host ""
    Pause
    exit 0
}
foreach ($f in $found) { Write-Host "  found $f" -ForegroundColor DarkGray }

# ============================================================
# [2/5] Stop the HTTP endpoint (task + any running process)
# ============================================================
Step 2 "Stopping the HTTP endpoint..."

if ($taskExists) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 1
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Ok "scheduled task '$TaskName' deleted"
    } catch {
        Warn "could not delete the task: $($_.Exception.Message)"
    }
} else { Skip "no autostart task" }

$killed = 0
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*server-http.mjs*" -or $_.CommandLine -like "*begemot-mcp*" } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ } catch {}
    }
# The supervisor is a powershell process that owns the server as a child. If it
# is left alive it simply restarts the server afterwards and undoes the removal,
# so it must be stopped too. Anchored on the deploy path so this script itself
# (or any unrelated powershell) can never match.
$watchdogs = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.EXE'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '\\begemot-mcp\\watchdog\.ps1' } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $watchdogs++ } catch {}
    }
if ($killed) { Ok "$killed server process(es) stopped" } else { Skip "no server process running" }
if ($watchdogs) { Ok "$watchdogs watchdog process(es) stopped" } else { Skip "no watchdog running" }

# give the port a moment to be released
Start-Sleep -Seconds 1
try {
    $probe = Invoke-WebRequest -Uri "http://127.0.0.1:$HttpPort/health" -TimeoutSec 2 -UseBasicParsing
    Warn "port $HttpPort still answers - another program may be using it"
} catch { Skip "port $HttpPort is free" }

# ============================================================
# [3/5] Clean the OpenCode config (surgical, comments preserved)
# ============================================================
Step 3 "Cleaning the OpenCode config..."

if ($cfgFiles.Count) {
    # The removal module lives next to the installer in the deployed tree.
    # Older installs do not have it, so fetch it (and the scanner it imports)
    # from GitHub into a temp dir and use that instead.
    $localMod = Join-Path $McpDir "installer\unmerge-opencode-config.mjs"
    $workDir  = ""
    if (Test-Path $localMod -PathType Leaf) {
        $workDir = Split-Path $localMod
        Skip "using the deployed removal module"
    } else {
        $workDir = Join-Path $env:TEMP "begemot-uninstall"
        if (-not (Test-Path $workDir)) { New-Item -Path $workDir -ItemType Directory -Force | Out-Null }
        foreach ($mod in @("unmerge-opencode-config.mjs", "merge-opencode-config.mjs")) {
            $dst = Join-Path $workDir $mod
            if (-not (Test-Path $dst)) {
                $rawUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/installer/$mod"
                try {
                    Invoke-WebRequest -Uri $rawUrl -OutFile $dst -UseBasicParsing
                    Ok "$mod fetched from GitHub"
                } catch {
                    Die "cannot obtain $mod ($($_.Exception.Message)) - nothing was removed from the config"
                }
            }
        }
    }

    $unmerge = Join-Path $workDir "unmerge-opencode-config.mjs"
    $nodeCmd = $null
    try { $nodeCmd = Get-Command node -ErrorAction Stop } catch {}
    if (-not $nodeCmd) { Die "node not on PATH - remove the entry from your opencode config by hand" }
    $NodeExe = $nodeCmd.Source

    foreach ($p in $cfgFiles) {
        $bak = "$p.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        try { Copy-Item $p $bak -Force; Write-Host "  backup: $bak" -ForegroundColor DarkGray } catch {}
    }

    $eap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $NodeExe $unmerge $ConfigDir $PromptFile $PluginDst 2>&1 }
    finally { $ErrorActionPreference = $eap }
    if ($LASTEXITCODE -ne 0) { Die "config cleanup failed (exit $LASTEXITCODE)" }
    Ok "Begemot entries removed from the config, everything else kept"
} else { Skip "config has no Begemot entries" }

# let the running OpenCode drop the server from its cache
$CliPath = ""
$cliCandidates = @(
    (Join-Path $env:LOCALAPPDATA "Programs\@opencodedesktop\resources\opencode-cli.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\opencode\opencode-cli.exe"),
    (Join-Path $env:LOCALAPPDATA "opencode\opencode-cli.exe"),
    (Join-Path $env:ProgramFiles "OpenCode\opencode-cli.exe")
)
foreach ($cand in $cliCandidates) {
    if ($cand -and (Test-Path $cand)) { $CliPath = $cand; break }
}
if (-not $CliPath) {
    $cmdInfo = Get-Command opencode-cli -ErrorAction SilentlyContinue
    if (-not $cmdInfo) { $cmdInfo = Get-Command opencode -ErrorAction SilentlyContinue }
    if ($cmdInfo) { $CliPath = $cmdInfo.Source }
}
if ($CliPath) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $CliPath service restart 2>&1 | Out-Null } catch {}
    finally { $ErrorActionPreference = $eap }
    Skip "OpenCode service restarted so it reloads the config"
}

# ============================================================
# [4/5] Remove the files
# ============================================================
Step 4 "Removing files..."

if (Test-Path $PromptFile) {
    try { Remove-Item $PromptFile -Force; Ok "prompt removed" } catch { Warn "prompt: $($_.Exception.Message)" }
} else { Skip "no prompt file" }

if (Test-Path $PluginDst) {
    try { Remove-Item $PluginDst -Recurse -Force; Ok "plugin removed" } catch { Warn "plugin: $($_.Exception.Message)" }
} else { Skip "no plugin" }

if (Test-Path $McpDir) {
    if ($KeepServerDir) {
        Skip "server tree kept (-KeepServerDir): $McpDir"
    } else {
        try {
            Remove-Item $McpDir -Recurse -Force
            Ok "server tree removed: $McpDir"
        } catch {
            Warn "server tree: $($_.Exception.Message)"
            Warn "a process may still hold a file - close OpenCode and re-run"
        }
    }
} else { Skip "no server tree" }

if ($PurgeBackups) {
    $baks = @(Get-ChildItem -Path $ConfigDir -Filter "opencode.json*.bak.*" -File -ErrorAction SilentlyContinue)
    if ($baks.Count) {
        foreach ($b in $baks) { try { Remove-Item $b.FullName -Force } catch {} }
        Ok "$($baks.Count) config backup(s) purged"
    } else { Skip "no backups to purge" }
}

# ============================================================
# [5/5] Verify
# ============================================================
Step 5 "Verifying..."

$left = @()
if (Test-Path $McpDir)     { $left += "server tree still present" }
if (Test-Path $PromptFile) { $left += "prompt still present" }
if (Test-Path $PluginDst)  { $left += "plugin still present" }
try { if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { $left += "task still registered" } } catch {}
foreach ($cf in @("opencode.jsonc", "opencode.json")) {
    $p = Join-Path $ConfigDir $cf
    if (Test-Path $p) {
        $txt = [IO.File]::ReadAllText($p)
        if ($txt -like "*$ServerName*" -or $txt -like "*begemot_prompt*" -or $txt -like "*greenlight*") {
            $left += "$cf still references Begemot"
        }
    }
}
$running = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*server-http.mjs*" })
if ($running.Count) { $left += "$($running.Count) server process(es) still running" }
# a surviving supervisor would resurrect the server, so it counts as leftover
$wdRunning = @(Get-CimInstance Win32_Process -Filter "Name='powershell.EXE'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '\\begemot-mcp\\watchdog\.ps1' })
if ($wdRunning.Count) { $left += "$($wdRunning.Count) watchdog process(es) still running" }

Write-Host ""
if ($left.Count) {
    foreach ($l in $left) { Warn "remaining: $l" }
    Write-Host "  Some pieces are still there - see the WARN lines above." -ForegroundColor Yellow
} else {
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host "  UNINSTALL COMPLETE - nothing left behind" -ForegroundColor Green
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Your own servers, rules and plugins were not touched." -ForegroundColor Cyan
    if (-not $PurgeBackups) {
        Write-Host "  Config backups are kept: $ConfigDir\opencode.json*.bak.*" -ForegroundColor DarkGray
        Write-Host "  (re-run with -PurgeBackups to delete them)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  To install again:" -ForegroundColor Cyan
    Write-Host "  irm https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/installer/install_begemot_opencode.ps1 | iex" -ForegroundColor DarkGray
    Write-Host ""
}
Pause
