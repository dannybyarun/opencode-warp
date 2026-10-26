#Requires -Version 5.1
#
# warp-rotate.ps1 - recover a throttled WARP ingress (Windows).
#
# Probes the current WARP egress once. If the free tier is throttled, removes
# the anonymous WARP device registration, creates a new one, reconnects in
# proxy mode, and probes again. Repeats up to WARP_ROTATE_ATTEMPTS times.
#
# This is the automated version of:
#
#   warp-cli --accept-tos disconnect
#   warp-cli --accept-tos registration delete
#   warp-cli --accept-tos registration new
#   warp-cli --accept-tos mode proxy
#   warp-cli --accept-tos proxy port 40000
#   warp-cli --accept-tos connect
#   .\probe.ps1
#
# Exit codes:  0 = healthy or recovered
#              1 = still throttled / still failing after all rotations
#              2 = no verdict (probe/warp-cli/proxy failure)
#
# Options:     --force         rotate first, without probing the current ingress
#              --rotate-only   replace the registration and verify the proxy,
#                              but do not run an opencode probe (used by the
#                              real-time plugin during a live session)
#
# Environment:
#   WARP_ROTATE_ATTEMPTS   rotation attempts (default 2)
#   WARP_PROXY_PORT        WARP proxy port (default 40000)
#   OPENCODE_WARP_PROBE    probe.ps1 path (default: next to this script,
#                          then %LOCALAPPDATA%\opencode-warp\bin\probe.ps1)
#   PROBE_MODEL            forwarded to probe.ps1
#   PROBE_RUN              forwarded to probe.ps1

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$force = $false
$rotateOnly = $false
foreach ($argument in $args) {
  switch -Regex ($argument) {
    "^(--force|-Force)$" { $force = $true; continue }
    "^(--rotate-only|-RotateOnly)$" { $rotateOnly = $true; continue }
    "^(--help|-h|-Help)$" {
      Write-Output "warp-rotate.ps1 - recover a throttled WARP ingress"
      Write-Output ""
      Write-Output "Usage: warp-rotate.ps1 [--force] [--rotate-only]"
      Write-Output ""
      Write-Output "  --force        rotate first, without probing the current ingress"
      Write-Output "  --rotate-only  rotate and verify the proxy, no opencode probe"
      Write-Output ""
      Write-Output "Environment: WARP_ROTATE_ATTEMPTS (default 2), WARP_PROXY_PORT (default 40000)"
      exit 0
    }
    default {
      [Console]::Error.WriteLine("opencode-warp: unknown option: $argument")
      exit 2
    }
  }
}

$port = 40000
if ($env:WARP_PROXY_PORT) {
  $parsedPort = 0
  if ([int]::TryParse($env:WARP_PROXY_PORT, [ref]$parsedPort) -and $parsedPort -gt 0 -and $parsedPort -le 65535) {
    $port = $parsedPort
  }
}
$proxy = "http://127.0.0.1:$port"

$attempts = 2
if ($env:WARP_ROTATE_ATTEMPTS) {
  $parsedAttempts = 0
  if (-not ([int]::TryParse($env:WARP_ROTATE_ATTEMPTS, [ref]$parsedAttempts)) -or $parsedAttempts -lt 1) {
    $attempts = 1
  } else {
    $attempts = $parsedAttempts
  }
}

# Serialise concurrent `opencode --stand` launches: two rotations deleting each
# other's registrations would be worse than either one alone. FileShare.None
# gives an exclusive lock on Windows; on Unix .NET enforces it with flock.
$paths = Get-OpenCodeWarpPaths
if (-not (Test-Path -LiteralPath $paths.State -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $paths.State | Out-Null
}
$lockPath = Join-Path $paths.State "rotate.lock"
$lockStream = $null
$lockDeadline = (Get-Date).AddSeconds(90)
while ($true) {
  try {
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    break
  } catch {
    if ((Get-Date) -ge $lockDeadline) {
      [Console]::Error.WriteLine("opencode-warp: another rotation is already in progress")
      exit 2
    }
    Start-Sleep -Milliseconds 500
  }
}

$probe = $null
if (-not $rotateOnly) {
  $probe = Find-Probe
  if (-not $probe) {
    Write-Say "cannot find probe.ps1 (set OPENCODE_WARP_PROBE)"
    if ($lockStream) { $lockStream.Dispose() }
    exit 2
  }
}

$probeOut = Join-Path ([IO.Path]::GetTempPath()) ("opencode-warp-rotate-" + [Guid]::NewGuid().ToString("N") + ".out")

function Invoke-Probe {
  $environment = @{ OPENCODE_WARP_NO_ROTATE = "1" }
  $result = Invoke-ScriptCaptured -ScriptPath $probe -Environment $environment -TimeoutSec 180
  [IO.File]::WriteAllText($probeOut, $result.Output, [Text.Encoding]::UTF8)
  return $result.ExitCode
}

# Show the egress that probe.ps1 recorded. This runs for every probe, not just
# a successful one, so a still-throttled rotation can be checked against the
# previous IP/location instead of being a black box.
function Write-Egress {
  param([string]$Label)
  $lines = @((Read-TextFile $probeOut) -split "`r?`n" | Where-Object { $_ -match "^(ip|loc|warp)=" })
  if ($lines.Count -eq 0) { return }
  [Console]::Error.WriteLine("opencode-warp: $Label")
  foreach ($line in $lines) {
    [Console]::Error.WriteLine("  " + $line)
  }
}

function Invoke-WarpCli {
  param([string[]]$Arguments)
  $warpCli = Find-WarpCli
  if (-not $warpCli) {
    return [pscustomobject]@{ ExitCode = 127; Output = "warp-cli not found" }
  }
  return Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments $Arguments
}

function Test-RotationReady {
  $warpCli = Find-WarpCli
  if (-not $warpCli) {
    Write-Say "warp-cli not found"
    return $false
  }

  # Best effort: a connected client can refuse to delete its registration.
  $null = Invoke-WarpCli @("--accept-tos", "disconnect")

  Write-Say "deleting the WARP device registration"
  $deleted = Invoke-WarpCli @("--accept-tos", "registration", "delete")
  if ($deleted.ExitCode -ne 0) {
    Write-Warn "registration delete returned non-zero; continuing"
  }

  Write-Say "creating a new anonymous registration"
  $created = Invoke-WarpCli @("--accept-tos", "registration", "new")
  if ($created.ExitCode -ne 0) {
    Write-Say "registration new failed (run as Administrator, or check 'warp-cli status')"
    if ($created.Output.Trim()) {
      @($created.Output -split "`r?`n" | Select-Object -Last 4) | ForEach-Object {
        [Console]::Error.WriteLine("  $_")
      }
    }
    return $false
  }

  Write-Say "setting proxy mode on 127.0.0.1:$port"
  $mode = Invoke-WarpCli @("--accept-tos", "mode", "proxy")
  if ($mode.ExitCode -ne 0) {
    $mode = Invoke-WarpCli @("--accept-tos", "set-mode", "proxy")
  }
  if ($mode.ExitCode -ne 0) {
    Write-Say "could not set WARP proxy mode; refusing to connect"
    return $false
  }

  # Best effort: some clients only accept one of these spellings.
  $portSet = Invoke-WarpCli @("--accept-tos", "proxy", "port", [string]$port)
  if ($portSet.ExitCode -ne 0) {
    $portSet = Invoke-WarpCli @("--accept-tos", "set-proxy-port", [string]$port)
  }
  if ($portSet.ExitCode -ne 0) {
    Write-Warn "could not set the WARP proxy port; relying on the current setting"
  }

  $null = Invoke-WarpCli @("--accept-tos", "connect")

  # Capture first, then match. A pipeline plus early-exit match can report a
  # false failure when warp-cli dies on SIGPIPE (the same trap as Linux).
  $status = ""
  for ($i = 0; $i -lt 30; $i++) {
    $result = Invoke-WarpCli @("--accept-tos", "status")
    $status = $result.Output
    if ($status -match "Connected") { break }
    Start-Sleep -Seconds 1
  }
  if ($status -notmatch "Connected") {
    Write-Say "WARP did not reach Connected after rotation"
    return $false
  }

  # A failed proxy-mode switch plus a successful connect would turn WARP into a
  # full tunnel and change the machine's routing. Refuse that combination.
  $settingsResult = Invoke-WarpCli @("--accept-tos", "settings")
  $settings = $settingsResult.Output
  if ($settings -match "WarpProxy" -or $settings -imatch "mode:\s*proxy") {
    # proxy mode confirmed
  } elseif ($settings -imatch "mode:") {
    Write-Say "WARP is not in proxy mode after reconnect; disconnecting"
    $null = Invoke-WarpCli @("--accept-tos", "disconnect")
    return $false
  }

  # Status can say Connected before the local proxy accepts traffic.
  for ($i = 0; $i -lt 15; $i++) {
    if (Test-ProxyReachable -Proxy $proxy -TimeoutSec 3) { return $true }
    Start-Sleep -Seconds 1
  }
  Write-Say "proxy $proxy is unreachable after rotation"
  return $false
}

try {
  # Live-session path used by the OpenCode plugin. It must not run an
  # `opencode run` probe: that would start a nested OpenCode inside the session
  # that is waiting for this rotation. Reaching the local proxy is enough; the
  # retried model request is the real throttle test.
  if ($rotateOnly) {
    Write-Say "rotate-only: replacing the WARP registration"
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
      Write-Say "rotation attempt $attempt/$attempts"
      if (Test-RotationReady) {
        Write-StateEpoch "last-rotated" (Get-EpochSeconds)
        Write-Say "rotation complete; proxy $proxy is reachable"
        exit 0
      }
      Write-Say "rotation attempt $attempt failed"
      if ($attempt -lt $attempts) { Start-Sleep -Seconds 2 }
    }

    Write-StateEpoch "last-throttled" (Get-EpochSeconds)
    Write-Say "could not restore a reachable WARP proxy after $attempts attempt(s)"
    exit 2
  }

  $rotatedOk = $false

  if (-not $force) {
    Write-Say "checking the WARP ingress"
    $rc = Invoke-Probe
    Write-Egress "current ingress"

    switch ($rc) {
      0 {
        Write-Say "ingress is healthy; no rotation needed"
        Write-StateEpoch "last-ok" (Get-EpochSeconds)
        Remove-StateFile "last-throttled"
        exit 0
      }
      1 {
        # throttled; rotate below
      }
      3 {
        # The WARP tunnel itself is resetting connections. That is exactly the
        # kind of broken ingress a fresh registration fixes, so rotate instead
        # of treating it as an unclassifiable failure.
        Write-Say "transport failure through WARP; rotating"
      }
      default {
        Write-Say "no verdict from probe.ps1; not rotating"
        $tail = @((Read-TextFile $probeOut) -split "`r?`n")
        $start = [Math]::Max(0, $tail.Count - 8)
        for ($i = $start; $i -lt $tail.Count; $i++) {
          [Console]::Error.WriteLine("  " + $tail[$i])
        }
        if ($lockStream) { $lockStream.Dispose() }
        exit 2
      }
    }

    Write-StateEpoch "last-throttled" (Get-EpochSeconds)
    Write-Say "ingress is throttled or failing"
  }

  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    Write-Say "rotation attempt $attempt/$attempts"
    if (-not (Test-RotationReady)) {
      Write-StateEpoch "last-throttled" (Get-EpochSeconds)
      exit 2
    }

    Write-Say "probing the new ingress"
    $rc = Invoke-Probe
    Write-Egress "new ingress (attempt $attempt/$attempts)"
    switch ($rc) {
      0 { }
      1 { Write-Say "the new ingress is still throttled" }
      3 { Write-Say "the new ingress is resetting connections" }
      default {
        Write-Say "no verdict after rotation; not retrying"
        $tail = @((Read-TextFile $probeOut) -split "`r?`n")
        $start = [Math]::Max(0, $tail.Count - 8)
        for ($i = $start; $i -lt $tail.Count; $i++) {
          [Console]::Error.WriteLine("  " + $tail[$i])
        }
        Write-StateEpoch "last-throttled" (Get-EpochSeconds)
        exit 2
      }
    }

    if ($rc -eq 0) {
      Write-Say "recovered: the new ingress passes"
      Write-StateEpoch "last-ok" (Get-EpochSeconds)
      Remove-StateFile "last-throttled"
      $rotatedOk = $true
      break
    }
  }

  if ($rotatedOk) { exit 0 }

  Write-StateEpoch "last-throttled" (Get-EpochSeconds)
  Write-Say "the WARP ingress is still not passing after $attempts rotation attempt(s)"
  $tail = @((Read-TextFile $probeOut) -split "`r?`n")
  $start = [Math]::Max(0, $tail.Count - 8)
  for ($i = $start; $i -lt $tail.Count; $i++) {
    [Console]::Error.WriteLine("  " + $tail[$i])
  }
  exit 1
} finally {
  Remove-Item -LiteralPath $probeOut -Force -ErrorAction SilentlyContinue
  if ($lockStream) { $lockStream.Dispose() }
}
