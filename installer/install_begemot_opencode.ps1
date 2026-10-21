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
$ConfigFile = Join-Path $ConfigDir "opencode.jsonc"
$PromptFile = Join-Path $ConfigDir "begemot_prompt.md"
$PluginDst  = Join-Path $ConfigDir "plugins\greenlight"
$HttpPort   = 8788
$TaskName   = "BegemotMcpHttp"
$ApiKey     = "9db6f52871e4c30a"

$STEPS_TOTAL = 7

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
function Die($m)  { Err $m; Read-Host "Press Enter to close"; exit 1 }

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
# [1/7] Node.js
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
# [2/7] Fetch the current source from GitHub (no embedded payload)
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
# [3/7] Deploy files
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
# [4/7] npm install
# ============================================================
Step 4 "npm install..."
$npmResult = Start-Process -FilePath $NpmExe -ArgumentList @("install", "--no-audit", "--no-fund") `
    -WorkingDirectory $McpDir -Wait -PassThru -NoNewWindow
if ($npmResult.ExitCode -eq 0 -and (Test-Path (Join-Path $McpDir "node_modules\@modelcontextprotocol\sdk"))) {
    Ok "dependencies installed"
}
elseif ($npmResult.ExitCode -eq 0) {
    Warn "npm exited 0 but @modelcontextprotocol/sdk is missing - retry with: cd `"$McpDir`" && npm.cmd install"
}
else { Die "npm install failed (exit $($npmResult.ExitCode))" }

# ============================================================
# [5/7] Configure OpenCode (JSONC-safe merge + backup)
# ============================================================
Step 5 "Configuring OpenCode..."
if (-not (Test-Path $ConfigDir)) { New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null }
if (Test-Path $ConfigFile) {
    $backup = "$ConfigFile.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item $ConfigFile $backup -Force
    Write-Host "  backup: $backup" -ForegroundColor DarkGray
}

$nodeScript = Join-Path $env:TEMP "begemot_oc_merge.js"
@'
const fs = require('fs');
const cfgPath = process.argv[2];
const promptPath = process.argv[3];
const mcpDir = process.argv[4];
const nodeExe = process.argv[5] || 'node';
const pluginPath = process.argv[6];

function stripJsonc(s) {
    let out = '', i = 0, inStr = false, esc = false;
    while (i < s.length) {
        const c = s[i], n = s[i + 1];
        if (inStr) {
            out += c;
            if (esc) { esc = false; }
            else if (c === '\\') { esc = true; }
            else if (c === '"') { inStr = false; }
            i++; continue;
        }
        if (c === '"') { inStr = true; out += c; i++; continue; }
        if (c === '/' && n === '/') { while (i < s.length && s[i] !== '\n') i++; continue; }
        if (c === '/' && n === '*') { i += 2; while (i < s.length && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; continue; }
        out += c; i++;
    }
    return out;
}

let cfg = {};
if (fs.existsSync(cfgPath)) {
    const raw = fs.readFileSync(cfgPath, 'utf8').replace(/^\uFEFF/, '');
    const text = stripJsonc(raw).replace(/,\s*([}\]])/g, '$1');
    try { cfg = JSON.parse(text); }
    catch (e) { console.error('JSON parse failed: ' + e.message); process.exit(2); }
}
if (!cfg.mcp) cfg.mcp = {};
if (!cfg.mcp.servers) cfg.mcp.servers = {};
cfg.mcp.servers['begemot-traffic-light'] = {
    type: 'local',
    command: [nodeExe, mcpDir + '\\server.js'],
    codemode: false
};
if (!Array.isArray(cfg.instructions)) cfg.instructions = [];
if (!cfg.instructions.includes(promptPath)) cfg.instructions.push(promptPath);
if (pluginPath) {
    if (!Array.isArray(cfg.plugins)) cfg.plugins = [];
    const already = cfg.plugins.some((p) => typeof p === 'string' && p.replace(/\\/g, '/').indexOf('/plugins/greenlight') !== -1);
    if (!already) cfg.plugins.push(pluginPath);
}
fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2), 'utf8');
console.log('merged');
'@ | Set-Content $nodeScript -Encoding utf8

& $NodeExe $nodeScript $ConfigFile $PromptFile $McpDir $NodeExe $PluginDst
if ($LASTEXITCODE -ne 0) { Warn "config merge may have failed" }
else { Ok "opencode.jsonc updated" }
Remove-Item $nodeScript -ErrorAction SilentlyContinue

# ============================================================
# [6/7] Local Streamable HTTP endpoint (autostart, no Docker)
# ============================================================
Step 6 "Local HTTP endpoint on 127.0.0.1:$HttpPort (no Docker)..."

# stop a previous instance of this task so the new code is picked up
try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Seconds 1
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*server-http.mjs*" } |
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

$taskRegistered = $false
try {
    $action    = New-ScheduledTaskAction -Execute $NodeExe -Argument "server-http.mjs" -WorkingDirectory $McpDir
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden -RestartCount 3 `
                  -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Description "Begemot MCP Streamable HTTP on 127.0.0.1:$HttpPort" -Force | Out-Null
    $taskRegistered = $true
    Ok "autostart task '$TaskName' registered (runs at logon, hidden)"
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
# [7/7] Restart service + verify MCP
# ============================================================
Step 7 "Restarting OpenCode + verifying..."
if ($CliPath -and (Test-Path $CliPath)) {
    try { & $CliPath service restart 2>&1 | Out-Null; Ok "service restarted" }
    catch { Warn "service restart skipped" }
} else {
    Warn "opencode-cli.exe not found; restart the OpenCode app manually."
}

Start-Sleep -Seconds 2
if ($CliPath -and (Test-Path $CliPath)) {
    $list = & $CliPath mcp list 2>&1
    if ($list -match "begemot-traffic-light") { Ok "begemot-traffic-light connected" }
    else { Warn "MCP not listed yet (restart the OpenCode app)." }
}

# ============================================================
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Green
Write-Host "  INSTALL COMPLETE" -ForegroundColor Green
Write-Host "  ============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  MCP server   : $McpDir" -ForegroundColor Cyan
Write-Host "  Config       : $ConfigFile" -ForegroundColor Cyan
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
Read-Host "Press Enter to close"
