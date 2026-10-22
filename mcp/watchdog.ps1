# Begemot HTTP watchdog / supervisor (Windows).
#
# Why this exists
# ---------------
# The BegemotMcpHttp scheduled task used to run `node server-http.mjs` directly.
# If that process was killed - console closed, service restart, logoff, OOM kill
# - Windows Task Scheduler moved the task to "Ready" and never brought it back.
# Both failure-recovery mechanisms proved unreliable in practice:
#
#   * RestartOnFailure (PT1M / 3)  -> does not fire when the action is
#     force-killed. LastTaskResult comes back 0xFFFFFFFF and nothing restarts.
#   * A PT1M repetition on the LogonTrigger alone -> did not re-fire either.
#
# So the task no longer runs the server. It runs THIS script, which owns the
# server as a child process and restarts it whenever it goes missing or stops
# answering. A repeating TimeTrigger (PT1M) is registered alongside, so if the
# supervisor itself is killed, the task starts again within ~60 seconds.
#
# Recovery layers, outermost first:
#   1. supervisor notices the child died      -> restart in ~3s
#   2. supervisor itself killed               -> task trigger restarts it in ~60s
#   3. task not running at all (fresh logon)  -> logon trigger starts it
#
# The task is registered with MultipleInstancesPolicy=IgnoreNew and no execution
# time limit, so exactly one supervisor can ever be alive, and the others are
# silently discarded rather than stacking.
#
# Configuration lives in watchdog.config.json next to this script (written by
# the installer). Every key is optional and falls back to the default below.

param(
    # Overrides watchdog.config.json -> "node"; falls back to PATH lookup, then
    # the standard Windows install location.
    [string]$NodePath = "",
    # Overrides watchdog.config.json -> "port".
    [int]$Port = 0
)

$ErrorActionPreference = "Continue"

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Dir) { $Dir = (Get-Location).Path }

$CfgPath = Join-Path $Dir "watchdog.config.json"
$Cfg     = $null
if (Test-Path $CfgPath) {
    try { $Cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $Cfg = $null }
}

# --- resolve the entrypoint -------------------------------------------------
if (-not $NodePath) {
    if ($Cfg -and $Cfg.node) { $NodePath = [string]$Cfg.node }
}
if (-not $NodePath) {
    try { $NodePath = (Get-Command node -ErrorAction Stop).Source } catch { $NodePath = "" }
}
if (-not $NodePath -and (Test-Path "C:\Program Files\nodejs\node.exe")) {
    $NodePath = "C:\Program Files\nodejs\node.exe"
}
if (-not $NodePath) {
    # Last resort: let the task action's own environment resolve it.
    $NodePath = "node.exe"
}

if (-not $Port) {
    if ($Cfg -and $Cfg.port) { $Port = [int]$Cfg.port } else { $Port = 8788 }
}
if ($Cfg -and $Cfg.entry) { $Entry = [string]$Cfg.entry } else { $Entry = "server-http.mjs" }

$EntryPath = Join-Path $Dir $Entry
$Health    = "http://127.0.0.1:$Port/health"
$Log       = Join-Path $Dir "watchdog.log"
$StdOut    = Join-Path $Dir "server.out.log"
$StdErr    = Join-Path $Dir "server.err.log"

function Write-WatchdogLog([string]$Message) {
    try {
        $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        # keep the log from growing without bound
        if (Test-Path $Log) {
            $len = (Get-Item $Log -ErrorAction SilentlyContinue).Length
            if ($len -gt 1MB) { Set-Content -Path $Log -Value "" -Encoding UTF8 }
        }
        Add-Content -Path $Log -Value $line -Encoding UTF8
    } catch { }
}

function Test-BegemotHealth {
    try {
        $r = Invoke-WebRequest -Uri $Health -TimeoutSec 4 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Get-PortListeners {
    @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

Write-WatchdogLog ("=== watchdog start pid=" + $PID + " dir=" + $Dir +
                   " node=" + $NodePath + " port=" + $Port + " entry=" + $Entry + " ===")

if (-not (Test-Path $EntryPath)) {
    Write-WatchdogLog ("FATAL: entrypoint missing - " + $EntryPath + " (watchdog idle)")
    # Idle rather than spin: the task stays alive so the next file fix needs no
    # manual restart, and a missing file must not become a tight crash loop.
    while ($true) { Start-Sleep -Seconds 30 }
}

while ($true) {

    $listeners = Get-PortListeners

    if ($listeners.Count -gt 0) {

        # Something already owns the port. Give it a grace window before
        # condemning it - a transient slow health response must not get the
        # process killed.
        $failures = 0
        for ($i = 0; $i -lt 3; $i++) {
            if (Test-BegemotHealth) { break }
            $failures++
            Start-Sleep -Seconds 2
        }

        if ($failures -lt 3) {
            Start-Sleep -Seconds 3
            continue
        }

        foreach ($l in $listeners) {
            try {
                $procId = $l.OwningProcess
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                Write-WatchdogLog ("port " + $Port + " held but unhealthy - killed pid=" + $procId)
            } catch { }
        }
        Start-Sleep -Seconds 2
        continue
    }

    # Port is free: bring the server up.
    Write-WatchdogLog ("starting " + $Entry)
    $p = $null
    try {
        $p = Start-Process -FilePath $NodePath -ArgumentList $Entry `
            -WorkingDirectory $Dir -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr
        Write-WatchdogLog ("started pid=" + $p.Id)
    } catch {
        Write-WatchdogLog ("start FAILED: " + $_.Exception.Message)
        Start-Sleep -Seconds 3
        continue
    }

    # Wait up to 30s for it to become healthy, or bail out if it dies first.
    $ready = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if ($p.HasExited) { break }
        if (Test-BegemotHealth) { $ready = $true; break }
    }

    if (-not $ready) {
        if ($p.HasExited) {
            Write-WatchdogLog ("server pid=" + $p.Id + " exited code=" + $p.ExitCode + " during startup")
        } else {
            Write-WatchdogLog ("server pid=" + $p.Id + " did not become healthy in 30s")
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Seconds 3
        continue
    }

    Write-WatchdogLog ("healthy pid=" + $p.Id + " - entering supervise loop")

    # Supervise: leave this loop only when the server dies or stops answering.
    while ($true) {
        Start-Sleep -Seconds 3
        if ($p.HasExited) {
            Write-WatchdogLog ("server pid=" + $p.Id + " exited code=" + $p.ExitCode)
            break
        }
        if (-not (Test-BegemotHealth)) {
            Write-WatchdogLog ("server pid=" + $p.Id + " health check failed - restarting")
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
            Start-Sleep -Seconds 1
            break
        }
    }

    Start-Sleep -Seconds 3
}
