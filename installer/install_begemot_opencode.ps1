# Begemot MCP Auto-Installer for OpenCode
# =====================================
# Local install, no Docker, no containers: fetches the repo, deploys the MCP
# server, configures OpenCode and starts the local Streamable HTTP endpoint
# as a per-user autostart task.
#
# One-liner:
#   irm https://raw.githubusercontent.com/dfvjgjgjg-commits/begemot-mcp/main/installer/install_begemot_opencode.ps1 | iex
# =====================================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# --- repository ---
$RepoOwner = "dfvjgjgjg-commits"
$RepoName  = "begemot-mcp"
$Branch    = "main"
$RepoUrl   = "https://github.com/$RepoOwner/$RepoName"

# --- paths ---
$HomeDir    = $env:USERPROFILE
$McpDir     = Join-Path $HomeDir "Documents\MCP\begemot-mcp"
$ConfigDir  = Join-Path $HomeDir ".config\opencode"
$PromptFile = Join-Path $ConfigDir "begemot_prompt.md"
$PluginDst  = Join-Path $ConfigDir "plugins\greenlight"
$HttpPort   = 8788
$TaskName   = "BegemotMcpHttp"
$ApiKey     = "9db6f52871e4c30a"

$STEPS_TOTAL = 8

function Banner {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host "  BEGEMOT MCP - OpenCode Auto-Installer" -ForegroundColor Green
    Write-Host "  local install, no Docker" -ForegroundColor DarkGray
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host ""
}
function Step($n, $t) { Write-Host ""; Write-Host "[$n/$STEPS_TOTAL] $t" -ForegroundColor Yellow }
function Ok($m)   { Write-Host "  OK: $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  WARN: $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "  ERROR: $m" -ForegroundColor Red }
function Pause() {
    # Wait for a key only when a human is actually sitting at the console.
    # With a redirected stdin (CI, scheduled task, non-interactive host,
    # "irm ... | iex" from a service) Read-Host blocks forever and leaves the
    # installer running, holding its log file open.
    try {
        if ([Console]::IsInputRedirected) { return }
        if (-not [Environment]::UserInteractive) { return }
    } catch { return }
    Read-Host "Press Enter to close"
}
function Die($m)  { Err $m; Pause; exit 1 }

Banner

# --- opencode CLI discovery ---
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

# ============================================================
# [1/8] Node.js
# ============================================================
Step 1 "Node.js..."
$nodeCmd = $null
try { $nodeCmd = Get-Command node -ErrorAction Stop } catch {}
if (-not $nodeCmd) {
    Write-Host "  Node.js not found. Downloading..." -ForegroundColor Red
    $nodeUrl = "https://nodejs.org/dist/v22.12.0/node-v22.12.0-x64.msi"
    $installer = Join-Path $env:TEMP "node-setup.msi"
    try { Invoke-WebRequest -Uri $nodeUrl -OutFile $installer -UseBasicParsing }
    catch { Die "cannot download Node.js. Install manually: https://nodejs.org/" }
    Start-Process msiexec.exe -ArgumentList "/i `"$installer`" /qn /norestart" -Wait
    $env:PATH = "C:\Program Files\nodejs;$env:PATH"
    Start-Sleep -Seconds 5
    $nodeCmd = $null
    try { $nodeCmd = Get-Command node -ErrorAction Stop } catch {}
    if (-not $nodeCmd) { Die "Node.js installed but not on PATH. Reopen the console and re-run." }
    Remove-Item $installer -ErrorAction SilentlyContinue
}
$NodeExe = $nodeCmd.Source
Ok "Node.js $(& $NodeExe -v 2>$null)"
Write-Host "  node path: $NodeExe" -ForegroundColor DarkGray

$NpmExe = ""
$npmCmd = $null
try { $npmCmd = Get-Command npm -ErrorAction Stop } catch {}
# Get-Command prefers npm.ps1 on Windows; cmd.exe does not execute it (it
# returns 0 and does nothing), so resolve the .cmd/.exe shim explicitly.
$npmCandidates = @()
if ($npmCmd) { $npmCandidates += $npmCmd.Source }
$nodeDir = Split-Path $NodeExe
$npmCandidates += (Join-Path $nodeDir "npm.cmd")
$npmCandidates += (Join-Path $nodeDir "npm.exe")
foreach ($c in $npmCandidates) {
    if ($c -and (Test-Path $c) -and $c -notlike "*.ps1") { $NpmExe = $c; break }
}
if (-not $NpmExe) { Die "npm not found. Reinstall Node.js: https://nodejs.org/" }
Ok "npm: $NpmExe"

# ============================================================
# [2/8] Fetch the current source from GitHub (no embedded payload)
# ============================================================
Step 2 "Fetching $RepoOwner/$RepoName @ $Branch ..."
$SrcRoot = Join-Path $env:TEMP "begemot-src"
$SrcDir  = ""
if (Test-Path $SrcRoot) { Remove-Item $SrcRoot -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $SrcRoot -Force | Out-Null

function Test-SourceTree($dir) {
    return (Test-Path (Join-Path $dir "mcp\core.mjs")) -and
           (Test-Path (Join-Path $dir "mcp\server.js")) -and
           (Test-Path (Join-Path $dir "plugin\greenlight\index.js")) -and
           (Test-Path (Join-Path $dir "prompt\begemot_prompt.md"))
}

# the deployed directory is flat: mcp/* is copied to the root of $McpDir
function Test-DeployedTree($dir) {
    return (Test-Path (Join-Path $dir "core.mjs")) -and
           (Test-Path (Join-Path $dir "server.js")) -and
           (Test-Path (Join-Path $dir "server-http.mjs")) -and
           (Test-Path (Join-Path $dir "config.json")) -and
           (Test-Path (Join-Path $dir "package.json")) -and
           (Test-Path (Join-Path $dir "plugins\greenlight\index.js")) -and
           (Test-Path (Join-Path $dir "begemot_prompt.md"))
}

# preferred: git - always exactly what is on the branch
$gitCmd = $null
try { $gitCmd = Get-Command git -ErrorAction Stop } catch {}
if ($gitCmd) {
    $gitDir = Join-Path $SrcRoot "repo"
    # native tools write to stderr; under $ErrorActionPreference = 'Stop' a
    # redirected stderr becomes a terminating NativeCommandError, so relax it
    # for the duration of the call
    $eap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $gitExit = 1
    try {
        & $gitCmd.Source clone --depth 1 -b $Branch $RepoUrl $gitDir 2>&1 | Out-Null
        $gitExit = $LASTEXITCODE
    } catch { $gitExit = 1 }
    finally { $ErrorActionPreference = $eap }
    if ($gitExit -eq 0 -and (Test-SourceTree $gitDir)) { $SrcDir = $gitDir; Ok "cloned via git" }
}

# fallback: zip archive over HTTPS
if (-not $SrcDir) {
    $zip = Join-Path $env:TEMP "begemot-mcp.zip"
    try {
        Invoke-WebRequest -Uri "$RepoUrl/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $SrcRoot -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        foreach ($d in (Get-ChildItem -Path $SrcRoot -Directory)) {
            if (Test-SourceTree $d.FullName) { $SrcDir = $d.FullName; break }
        }
        if ($SrcDir) { Ok "downloaded archive" } else { Warn "archive layout not recognized" }
    } catch {
        Warn "archive download failed: $($_.Exception.Message)"
    }
}

if (-not $SrcDir) {
    Die "cannot fetch $RepoUrl - check network access (github.com must be reachable)."
}

# ============================================================
# [3/8] Deploy files
# ============================================================
Step 3 "Deploying to $McpDir ..."
if (-not (Test-Path $McpDir)) { New-Item -Path $McpDir -ItemType Directory -Force | Out-Null }
try {
    Copy-Item -Path (Join-Path $SrcDir "mcp\*") -Destination $McpDir -Recurse -Force
    $plugSrc = Join-Path $SrcDir "plugin\greenlight"
    $plugDstLocal = Join-Path $McpDir "plugins\greenlight"
    New-Item -ItemType Directory -Path $plugDstLocal -Force | Out-Null
    Copy-Item -Path (Join-Path $plugSrc "*") -Destination $plugDstLocal -Recurse -Force
    Copy-Item -Path (Join-Path $SrcDir "prompt\begemot_prompt.md") -Destination (Join-Path $McpDir "begemot_prompt.md") -Force
    # keep the deploy runbook + Dockerfile handy for reference (Docker is optional)
    foreach ($extra in @("remote", "installer", "CHANGELOG.md", "README.md")) {
        $p = Join-Path $SrcDir $extra
        if (Test-Path $p) { Copy-Item -Path $p -Destination $McpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
} catch { Die "deploy failed: $_" }

$deployed = Test-DeployedTree $McpDir
if (-not $deployed) { Die "deploy incomplete - core.mjs / server.js missing in $McpDir" }
Ok "files deployed (core.mjs, server.js, server-http.mjs, config.json, plugin, prompt)"

# prompt -> opencode config dir (where `instructions` points)
if (-not (Test-Path $ConfigDir)) { New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null }
Copy-Item -Path (Join-Path $McpDir "begemot_prompt.md") -Destination $PromptFile -Force
Ok "prompt -> $PromptFile"

# plugin -> opencode config dir
New-Item -ItemType Directory -Path $PluginDst -Force | Out-Null
Copy-Item -Path (Join-Path $McpDir "plugins\greenlight\*") -Destination $PluginDst -Recurse -Force
Ok "plugin  -> $PluginDst"

# ============================================================
# [4/8] npm install
# ============================================================
Step 4 "npm install..."
$npmResult = Start-Process -FilePath $NpmExe -ArgumentList @("install", "--no-audit", "--no-fund") `
    -WorkingDirectory $McpDir -Wait -PassThru -NoNewWindow
if ($npmResult.ExitCode -eq 0 -and (Test-Path (Join-Path $McpDir "node_modules\@modelcontextprotocol\sdk"))) {
    Ok "dependencies installed"
}
elseif ($npmResult.ExitCode -eq 0) {
    # npm can exit 0 and still leave the SDK out (offline mirror, broken cache).
    # Without it the stdio server cannot start, so this is fatal, not a warning.
    Die "npm exited 0 but @modelcontextprotocol/sdk is missing - run: cd `"$McpDir`" && npm install"
}
else { Die "npm install failed (exit $($npmResult.ExitCode))" }

# ============================================================
# [5/8] Configure OpenCode (surgical JSONC merge + backup)
# ============================================================
Step 5 "Configuring OpenCode..."
if (-not (Test-Path $ConfigDir)) { New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null }

# The merge is a separate module so both installers (Windows + POSIX) use the
# exact same logic, and so the config is edited as TEXT: comments, key order
# and formatting of the user survive. A parse/serialize round trip would wipe
# them and re-format the whole file.
$mergeScript = Join-Path $McpDir "installer\merge-opencode-config.mjs"
if (-not (Test-Path $mergeScript)) {
    $rawUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/installer/merge-opencode-config.mjs"
    try {
        Invoke-WebRequest -Uri $rawUrl -OutFile $mergeScript -UseBasicParsing
        Ok "merge module fetched from GitHub"
    } catch {
        Die "cannot obtain merge-opencode-config.mjs ($($_.Exception.Message))"
    }
}

# Back up every config file we are about to touch.
foreach ($cf in @("opencode.jsonc", "opencode.json")) {
    $p = Join-Path $ConfigDir $cf
    if (Test-Path $p) {
        $backup = "$p.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item $p $backup -Force
        Write-Host "  backup: $backup" -ForegroundColor DarkGray
    }
}

# The module writes into EVERY config file that exists (opencode.jsonc and
# opencode.json are unioned by OpenCode, so a single file could leave the
# entry shadowed by the other one's mcp block) and keeps each file's own
# shape: flat mcp.<name> stays flat, mcp.servers stays nested.
$mergeOut = & $NodeExe $mergeScript $ConfigDir $PromptFile $McpDir $NodeExe $PluginDst "auto" 2>&1
$mergeExit = $LASTEXITCODE
foreach ($line in $mergeOut) { Write-Host "  $line" -ForegroundColor DarkGray }
if ($mergeExit -ne 0) { Die "config merge failed (exit $mergeExit)" }
Ok "OpenCode config updated"

# ============================================================
# [6/8] Local Streamable HTTP endpoint (autostart, no Docker)
# ============================================================
Step 6 "Local HTTP endpoint on 127.0.0.1:$HttpPort (no Docker)..."

# stop a previous instance of this task so the new code is picked up
try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Seconds 1
# kill an old supervisor and an old direct-spawned server alike, otherwise a
# stale process keeps holding the port and the fresh one never starts
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*server-http.mjs*" } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
Get-CimInstance Win32_Process -Filter "Name='powershell.EXE'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '\\begemot-mcp\\watchdog\.ps1' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }

# wrapper script so the task has a stable entrypoint
$httpLauncher = Join-Path $McpDir "start-http.cmd"
@"
@echo off
cd /d "%~dp0"
set PORT=$HttpPort
set HOST=127.0.0.1
"$NodeExe" server-http.mjs
"@ | Set-Content $httpLauncher -Encoding ascii

# ---- supervisor configuration -------------------------------------------
# The task runs watchdog.ps1 rather than node directly. The watchdog owns the
# server as a child process and restarts it whenever it dies or stops answering
# (~3s recovery), so a killed server comes back on its own. See mcp/watchdog.ps1
# for the reasoning and the failure modes this replaces.
$watchdog = Join-Path $McpDir "watchdog.ps1"
$watchdogCfg = Join-Path $McpDir "watchdog.config.json"
$hasWatchdog = Test-Path $watchdog
if ($hasWatchdog) {
    @{
        node  = $NodeExe
        port  = $HttpPort
        entry = "server-http.mjs"
    } | ConvertTo-Json | Set-Content -Path $watchdogCfg -Encoding UTF8
    Ok "watchdog config -> $watchdogCfg"
} else {
    Warn "watchdog.ps1 not deployed - task will run the server directly (no self-heal)"
}

# Windows Task Scheduler's own RestartOnFailure does not fire when the action is
# force-killed (observed LastTaskResult 0xFFFFFFFF, no restart), so resilience
# comes from a repeating TimeTrigger instead: PT1M for 24h, re-armed at every
# install/logon. With MultipleInstancesPolicy=IgnoreNew a trigger that fires
# while the supervisor is alive is discarded; one that fires while it is dead
# brings the whole stack back within ~60s.
$taskRegistered = $false
try {
    if ($hasWatchdog) {
        $psExe  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.EXE"
        $psArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watchdog + '"'
        $action = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs -WorkingDirectory $McpDir
    } else {
        $action = New-ScheduledTaskAction -Execute $NodeExe -Argument "server-http.mjs" -WorkingDirectory $McpDir
    }

    $logonTrigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
                        -RepetitionInterval (New-TimeSpan -Minutes 1) `
                        -RepetitionDuration (New-TimeSpan -Hours 24)

    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden -RestartCount 3 `
                  -RestartInterval (New-TimeSpan -Minutes 1) `
                  -MultipleInstances IgnoreNew -StartWhenAvailable

    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger @($logonTrigger, $repeatTrigger) -Settings $settings `
        -Description "Begemot MCP Streamable HTTP on 127.0.0.1:$HttpPort" -Force | Out-Null
    $taskRegistered = $true
    if ($hasWatchdog) {
        Ok "autostart task '$TaskName' registered (watchdog, logon + 1min re-check, hidden)"
    } else {
        Ok "autostart task '$TaskName' registered (runs at logon, hidden)"
    }
} catch {
    Warn "could not register scheduled task: $($_.Exception.Message)"
    Warn "falling back to a plain background start"
}

# start it now
$started = $false
if ($taskRegistered) {
    try { Start-ScheduledTask -TaskName $TaskName; $started = $true } catch {}
}
if (-not $started) {
    try {
        Start-Process -FilePath $NodeExe -ArgumentList "server-http.mjs" -WorkingDirectory $McpDir `
            -WindowStyle Hidden -RedirectStandardOutput (Join-Path $env:TEMP "begemot_http.out") `
            -RedirectStandardError (Join-Path $env:TEMP "begemot_http.err") | Out-Null
        $started = $true
    } catch { Warn "background start failed: $($_.Exception.Message)" }
}

# verify health
$health = $null
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Milliseconds 800
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$HttpPort/health" -TimeoutSec 3 -UseBasicParsing
        $health = $r.Content
        break
    } catch { }
}
if ($health) { Ok "health: $health" }
else { Warn "endpoint not answering yet - check with: type $McpDir\*.log" }

# ============================================================
# [7/8] Restart service + verify MCP
# ============================================================
Step 7 "Restarting OpenCode + verifying..."
$restarted = $false
if ($CliPath -and (Test-Path $CliPath)) {
    $eap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $CliPath service restart 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $restarted = $true }
    } catch { }
    finally { $ErrorActionPreference = $eap }
    if ($restarted) { Ok "service restarted" }
    else { Warn "service restart failed - restart the OpenCode app by hand" }
} else {
    Warn "the opencode CLI was not found - restart the OpenCode app by hand"
}

Start-Sleep -Seconds 2
if ($CliPath -and (Test-Path $CliPath)) {
    $list = & $CliPath mcp list 2>&1
    if ($list -match "begemot-traffic-light") { Ok "begemot-traffic-light connected" }
    else { Warn "MCP not listed yet (restart the OpenCode app)." }
}

# ============================================================
# [8/8] Self-check: prove the server really starts and answers
# ============================================================
Step 8 "Self-check..."
$doctorScript = Join-Path $McpDir "installer\doctor.mjs"
if (-not (Test-Path $doctorScript)) {
    $rawUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/installer/doctor.mjs"
    try { Invoke-WebRequest -Uri $rawUrl -OutFile $doctorScript -UseBasicParsing }
    catch { Die "cannot obtain doctor.mjs ($($_.Exception.Message))" }
}
$eap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try { & $NodeExe $doctorScript --mcp-dir $McpDir --config-dir $ConfigDir --http-port $HttpPort }
finally { $ErrorActionPreference = $eap }
$doctorExit = $LASTEXITCODE
if ($doctorExit -ne 0) {
    Err "self-check FAILED - the install does not work yet"
    Err "fix the problem marked [FAIL] above, then re-run the installer"
    Die "self-check failed"
}
Ok "self-check passed - the MCP server starts and answers"

# ============================================================
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "  INSTALL COMPLETE" -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  MCP server   : $McpDir" -ForegroundColor Cyan
Write-Host "  Config dir   : $ConfigDir" -ForegroundColor Cyan
foreach ($cf in @("opencode.jsonc", "opencode.json")) {
    if (Test-Path (Join-Path $ConfigDir $cf)) { Write-Host "  Config file  : $cf" -ForegroundColor Cyan }
}
Write-Host "  Prompt       : $PromptFile" -ForegroundColor Cyan
Write-Host "  Plugin       : $PluginDst" -ForegroundColor Cyan
Write-Host "  HTTP endpoint: http://127.0.0.1:$HttpPort/mcp  (autostart, no Docker)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Connect OpenCode to it as a remote server:" -ForegroundColor Cyan
Write-Host "  `"headers`": { `"x-api-key`": `"$ApiKey`" }" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Stop / remove the HTTP autostart:" -ForegroundColor Cyan
Write-Host "  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Open a new chat in OpenCode. Begemot is active." -ForegroundColor Cyan
Write-Host ""
Pause
