#Requires -Version 5.1
#
# opencode-warp.ps1 - run opencode through the local Cloudflare WARP proxy.
#
# WARP runs in *proxy* mode on 127.0.0.1:40000, so this does not touch the
# machine's normal routing. Two things are injected:
#
#   HTTPS_PROXY / HTTP_PROXY  -> send outbound traffic through WARP
#   NO_PROXY                  -> opencode MUST still reach its own local
#                                background service, otherwise it 502s and
#                                dies with `service.ensure` errors
#
# Plus `--standalone`, because the background service is what actually makes
# inference calls. Env vars on the CLI alone never reach it. Two modes are
# exempt: `serve` is already a foreground server (and rejects --standalone),
# and `--server` connects to a server whose egress this process does not own.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$self = $PSCommandPath

$port = "40000"
if ($env:WARP_PROXY_PORT) { $port = $env:WARP_PROXY_PORT }
$proxy = "http://127.0.0.1:$port"

$allArgs = @($args)
# Accept `opencode-warp --stand ...` as a convenience too.
if ($allArgs.Count -gt 0 -and $allArgs[0] -eq "--stand") {
  if ($allArgs.Count -eq 1) {
    $allArgs = @()
  } else {
    $allArgs = $allArgs[1..($allArgs.Count - 1)]
  }
}

# --------------------------------------------------------------- run mode
# `serve` starts a foreground server: it rejects --standalone, and the server
# process itself owns the inference egress. `--server` connects to a server
# someone else started, so its egress is that server's business. Every other
# invocation gets --standalone, because the shared background service
# otherwise makes the inference calls outside this environment.
$mode = "standalone"
# Skip values of flags that take one, so a prompt that literally says
# "--server" cannot turn a normal run into a passthrough.
$needServerValue = $false
foreach ($argument in $allArgs) {
  if ($needServerValue) { $needServerValue = $false; continue }
  $text = [string]$argument
  if ($text -eq "--server") {
    $mode = "server"
    $needServerValue = $true
    continue
  }
  if ($text -like "--server=*") {
    $mode = "server"
    continue
  }
  if ($text -match "^(--session|-s|--prompt|--log-level|--completions|--model|-m)$") {
    $needServerValue = $true
  }
}

if ($mode -ne "server") {
  $firstCommand = ""
  $needValue = $false
  foreach ($argument in $allArgs) {
    if ($needValue) { $needValue = $false; continue }
    $text = [string]$argument
    if ($text -match "^(--session|-s|--prompt|--log-level|--completions|--model|-m)$") {
      $needValue = $true
      continue
    }
    if ($text -match "^--") { continue }
    $firstCommand = $text
    break
  }
  if ($firstCommand -eq "serve") { $mode = "serve" }
}

$opencode = Find-OpenCode
if (-not $opencode) {
  [Console]::Error.WriteLine("opencode-warp: cannot find the opencode binary")
  [Console]::Error.WriteLine("  install opencode first, or set OPENCODE_WARP_OPENCODE=/path/to/opencode")
  exit 127
}

if ($mode -eq "server") {
  # Do not inject the proxy env here: the target server owns its own egress,
  # and proxying this client's connection to a remote server through the local
  # WARP proxy would be wrong. No preflight either.
  try {
    & $opencode @allArgs
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    exit $code
  } catch {
    [Console]::Error.WriteLine("opencode-warp: failed to start opencode: " + $_.Exception.Message)
    exit 1
  }
}

$autoRotate = $true
if ($env:OPENCODE_WARP_AUTO_ROTATE) {
  if ($env:OPENCODE_WARP_AUTO_ROTATE -imatch "^(0|no|off|false)$") { $autoRotate = $false }
}

$requestedModel = ""
$needModelValue = $false
$skipPreflight = $false
foreach ($argument in $allArgs) {
  switch -Regex ($argument) {
    "^(--version|-v|--help|-h|--completions|--wizard)$" {
      $skipPreflight = $true
      $needModelValue = $false
      continue
    }
    "^--model=(.*)$" {
      $requestedModel = $Matches[1]
      $needModelValue = $false
      continue
    }
    "^(--model|-m)$" {
      $needModelValue = $true
      continue
    }
    default {
      if ($needModelValue) {
        $requestedModel = $argument
        $needModelValue = $false
      }
    }
  }
}

if ($skipPreflight) { $autoRotate = $false }
if ($requestedModel -and $requestedModel -notmatch "free") {
  # Explicit paid model: rotating the free bucket is pointless.
  $autoRotate = $false
}

# Guard against a future opencode that drops `--standalone`. Without it the
# proxy env vars would be silently ignored (the background service makes the
# inference calls) and opencode would quietly use normal egress. Failing loudly
# beats degrading silently. `serve` and `--server` never get the flag.
if ($mode -eq "standalone" -and -not (Test-OpenCodeStandalone $opencode)) {
  $version = Get-OpenCodeVersion $opencode
  [Console]::Error.WriteLine('opencode-warp: this opencode has no "run --standalone" flag')
  [Console]::Error.WriteLine("  version: $version")
  [Console]::Error.WriteLine("  the wrapper requires it; refusing to run, because without it the")
  [Console]::Error.WriteLine("  proxy would be silently ignored and normal egress used instead.")
  exit 1
}

if (-not (Test-ProxyReachable -Proxy $proxy -TimeoutSec 5)) {
  # WARP may simply not be connected yet - try to bring it up rather than fail.
  $warpCli = Find-WarpCli
  if ($warpCli) {
    $null = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("connect")
    Start-Sleep -Seconds 4
  }
  if (-not (Test-ProxyReachable -Proxy $proxy -TimeoutSec 5)) {
    [Console]::Error.WriteLine("opencode-warp: WARP proxy unreachable on $proxy")
    if ($warpCli) {
      [Console]::Error.WriteLine("  check: & `"$warpCli`" status")
    } else {
      [Console]::Error.WriteLine("  check: warp-cli status")
    }
    [Console]::Error.WriteLine("  setup: .\windows\setup.ps1")
    exit 1
  }
}

function Test-PreflightNeeded {
  if (-not $autoRotate) { return $false }
  if ($env:OPENCODE_WARP_NO_ROTATE -eq "1") { return $false }
  if ($env:OPENCODE_WARP_FORCE_PROBE -eq "1") { return $true }

  $lastThrottled = Read-StateEpoch "last-throttled"
  $lastOk = Read-StateEpoch "last-ok"
  if ($null -ne $lastThrottled) {
    if ($null -eq $lastOk -or $lastThrottled -gt $lastOk) { return $true }
  }

  $lastRateLimit = Get-LastRateLimitEpoch
  if ($null -eq $lastRateLimit) { return $false }
  if ($null -eq $lastOk) { return $true }
  return ($lastRateLimit -gt $lastOk)
}

if (Test-PreflightNeeded) {
  $rotate = Find-Rotate
  if (-not $rotate) {
    [Console]::Error.WriteLine("opencode-warp: detected a rate limit, but warp-rotate.ps1 is missing")
    [Console]::Error.WriteLine("  re-run setup.ps1, or set OPENCODE_WARP_AUTO_ROTATE=0 to skip")
    exit 1
  }

  [Console]::Error.WriteLine("opencode-warp: rate limit detected in the opencode log; checking WARP")
  if ($requestedModel -and -not $env:PROBE_MODEL) {
    $env:PROBE_MODEL = $requestedModel
  }

  # The raw API probe can be gated for free models, so a rotation decision
  # must use the real client. warp-rotate.ps1 defaults to CLI mode too; set it
  # here as well so a custom rotation helper inherits the same contract. Only
  # hand it the wrapper path when the probe has to go through `opencode run`
  # (a third-party provider), because PROBE_RUN forces CLI mode.
  if (-not $env:PROBE_MODE) { $env:PROBE_MODE = "cli" }
  $rotationEnv = @{ OPENCODE_WARP_NO_ROTATE = "1" }
  if ($requestedModel -and $requestedModel -notmatch "^opencode/") {
    $rotationEnv["PROBE_RUN"] = $self
  }

  $rotation = Invoke-ScriptCaptured -ScriptPath $rotate -Environment $rotationEnv -TimeoutSec 600
  $rc = $rotation.ExitCode
  $rotationText = $rotation.Output.TrimEnd()
  if ($rotationText) {
    foreach ($line in ($rotationText -split "`r?`n")) {
      [Console]::Error.WriteLine($line)
    }
  }

  switch ($rc) {
    0 { }
    1 {
      [Console]::Error.WriteLine("opencode-warp: WARP recovery did not produce a healthy ingress; starting opencode anyway")
      if ($env:OPENCODE_WARP_ROTATE_STRICT -eq "1") { exit 1 }
    }
    default {
      if ($env:OPENCODE_WARP_ROTATE_STRICT -eq "1") {
        [Console]::Error.WriteLine("opencode-warp: could not get a verdict from the WARP ingress (exit $rc);")
        [Console]::Error.WriteLine("  refusing to start because OPENCODE_WARP_ROTATE_STRICT=1.")
        [Console]::Error.WriteLine("  check: warp-cli status  /  .\probe.ps1")
        exit $rc
      }
      if (Test-ProxyReachable -Proxy $proxy -TimeoutSec 5) {
        [Console]::Error.WriteLine("opencode-warp: warning: could not get a model verdict through WARP (exit $rc),")
        [Console]::Error.WriteLine("  but the WARP proxy itself is reachable; starting opencode anyway.")
        [Console]::Error.WriteLine("  set OPENCODE_WARP_ROTATE_STRICT=1 to make this fatal.")
      } else {
        [Console]::Error.WriteLine("opencode-warp: could not verify the new ingress and the WARP proxy is")
        [Console]::Error.WriteLine("  unreachable; refusing to start opencode through a broken WARP path.")
        [Console]::Error.WriteLine("  check: warp-cli status  /  .\probe.ps1")
        exit $rc
      }
    }
  }
}

$env:HTTPS_PROXY = $proxy
$env:HTTP_PROXY = $proxy
$env:https_proxy = $proxy
$env:http_proxy = $proxy
$env:NO_PROXY = "127.0.0.1,localhost,::1"
$env:no_proxy = "127.0.0.1,localhost,::1"

$finalArgs = @($allArgs)
if ($mode -eq "standalone") { $finalArgs += "--standalone" }
try {
  & $opencode @finalArgs
  $code = $LASTEXITCODE
  if ($null -eq $code) { $code = 0 }
  exit $code
} catch {
  [Console]::Error.WriteLine("opencode-warp: failed to start opencode: " + $_.Exception.Message)
  exit 1
}
