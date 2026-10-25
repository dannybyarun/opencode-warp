#Requires -Version 5.1
#
# probe.ps1 - one-shot verdict for the WARP path (Windows).
#
# Reports the current WARP egress, fires exactly ONE opencode request and
# prints SUCCESS / THROTTLED / TRANSPORT FAILURE / NO VERDICT. It never loops
# or retries.
#
# Exit codes:  0 = success
#              1 = throttled (429 / free-tier quota)
#              2 = no verdict (missing binary, auth error, timeout...)
#              3 = transport failure through WARP (ECONNRESET and friends)
#
# Overrides:   PROBE_RUN      command/script to run (default: opencode-warp.ps1)
#              PROBE_MODEL    model id
#              PROXY          proxy url to report egress from
#              PROBE_TIMEOUT  seconds before giving up (default 45)
#              PROBE_OUT      capture file
#
# This script is deliberately one-shot: never let the wrapper it launches run
# its own preflight rotation, which would recurse.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# This process exists only to test the ingress.
$env:OPENCODE_WARP_NO_ROTATE = "1"

$port = "40000"
if ($env:WARP_PROXY_PORT) { $port = $env:WARP_PROXY_PORT }

$proxy = $env:PROXY
if (-not $proxy) { $proxy = "http://127.0.0.1:$port" }

$model = $env:PROBE_MODEL
if (-not $model) { $model = "opencode/deepseek-v4.1-flash-free" }

$timeout = 45
if ($env:PROBE_TIMEOUT) {
  $parsedTimeout = 0
  if ([int]::TryParse($env:PROBE_TIMEOUT, [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
    $timeout = $parsedTimeout
  }
}

$outFile = $env:PROBE_OUT
if (-not $outFile) {
  $outFile = Join-Path ([IO.Path]::GetTempPath()) ("opencode-warp-probe-" + [Guid]::NewGuid().ToString("N") + ".out")
}
$outDirectory = Split-Path -Parent $outFile
if ($outDirectory -and -not (Test-Path -LiteralPath $outDirectory -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $outDirectory | Out-Null
}
$errFile = $outFile + ".stderr"

$run = $env:PROBE_RUN
if (-not $run) {
  $sibling = Join-Path $PSScriptRoot "opencode-warp.ps1"
  if (Test-Path -LiteralPath $sibling -PathType Leaf) {
    $run = $sibling
  } else {
    $run = "opencode-warp"
  }
}
if (-not (Test-Path -LiteralPath $run -PathType Leaf)) {
  $resolved = Get-CommandPath $run
  if ($resolved) { $run = $resolved }
}

$transportPattern = "ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENETUNREACH|EHOSTUNREACH|socket connection was closed|fetch failed"

Write-Output "--- egress (WARP) ---"
foreach ($line in (Get-EgressTrace -Proxy $proxy)) {
  Write-Output $line
}

Write-Output "--- one request through WARP ---"

if (-not (Test-Path -LiteralPath $run -PathType Leaf)) {
  Write-Output "RESULT: NO VERDICT -- cannot find the probe runner: $run"
  exit 2
}

$commandLine = Get-ExternalCommandLine -Path $run -Arguments @(
  "run", "-m", $model, "reply with exactly: PONG"
)

$startArgs = @{
  FilePath               = $commandLine.FilePath
  PassThru               = $true
  RedirectStandardOutput = $outFile
  RedirectStandardError  = $errFile
}
if ($commandLine.Arguments) { $startArgs.ArgumentList = $commandLine.Arguments }
if (Test-IsWindows) { $startArgs.WindowStyle = "Hidden" }

$early = $false
$timedOut = $false
$rc = 124
$process = $null

try {
  $process = Start-Process @startArgs
  $deadline = (Get-Date).AddSeconds($timeout)

  while (-not $process.HasExited) {
    if ((Get-Date) -ge $deadline) {
      $timedOut = $true
      break
    }

    $partial = (Read-TextFile $outFile) + (Read-TextFile $errFile)
    if ($partial -imatch $transportPattern) {
      $early = $true
      break
    }

    Start-Sleep -Milliseconds 250
    $process.Refresh()
  }

  if ($early -or $timedOut) {
    Stop-ProcessTree $process
    $null = $process.WaitForExit(5000)
  } else {
    $process.WaitForExit()
    $rc = $process.ExitCode
  }
} catch {
  $rc = 127
  [IO.File]::AppendAllText($outFile, $_.Exception.Message + "`r`n", [Text.Encoding]::UTF8)
}

if ($early -or $timedOut) { $rc = 124 }

# Keep PROBE_OUT as a single combined file, like the Linux `>file 2>&1`.
$stderrText = Read-TextFile $errFile
if ($stderrText) {
  [IO.File]::AppendAllText($outFile, $stderrText, [Text.Encoding]::UTF8)
}
Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue

$output = Read-TextFile $outFile

# 1. success: the model actually answered
if ($output -cmatch "PONG") {
  Write-Output "RESULT: SUCCESS (exit $rc) -> PONG"
  exit 0
}

# 2. throttled: match opencode's own wording, not any plugin's bookkeeping
if ($output -imatch "rate limit exceeded|free usage limit reached|free messages|too many requests|429") {
  Write-Output "RESULT: THROTTLED (exit $rc)"
  @($output -split "`r?`n" | Where-Object {
      $_ -imatch "rate limit exceeded|free usage limit reached|free messages|too many requests|429"
    } | Select-Object -First 2) | ForEach-Object { Write-Output "  opencode said: $_" }

  $log = $env:OPENCODE_RATELIMIT_LOG
  if (-not $log) { $log = Join-Path (Get-OpenCodeDataDir) "ratelimit-retry.jsonl" }
  if (Test-Path -LiteralPath $log -PathType Leaf) {
    try {
      $rows = Get-Content -LiteralPath $log -Tail 200 -ErrorAction Stop
      $last = $null
      foreach ($row in $rows) {
        if (-not $row.Trim()) { continue }
        try {
          $parsed = $row | ConvertFrom-Json
          if ($parsed.event -eq "http.response.429") { $last = $parsed }
        } catch {
          # Ignore malformed lines; the verdict never depends on this file.
        }
      }
      if ($last) {
        if ($last.ts) {
          try {
            $at = [DateTimeOffset]::Parse([string]$last.ts, [Globalization.CultureInfo]::InvariantCulture)
            $delay = 0
            if ($last.parsedDelayMs) { $delay = [double]$last.parsedDelayMs }
            $deadline = $at.AddMilliseconds($delay).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
            Write-Output "  unblocks   : $deadline"
          } catch {
            # no unblock estimate
          }
        }
        if ($last.headers -and $last.headers.'cf-ray') {
          Write-Output ("  cf-ray     : " + $last.headers.'cf-ray')
        }
      }
    } catch {
      # Observability only.
    }
  }
  exit 1
}

# 3. transport failure: the WARP path accepted the connection and then the
#    socket died. A fresh registration is the usual fix.
if ($output -imatch $transportPattern) {
  Write-Output "RESULT: TRANSPORT FAILURE (exit $rc) -- the connection through WARP died:"
  @($output -split "`r?`n" | Where-Object { $_ -imatch $transportPattern } |
      Select-Object -First 2) | ForEach-Object { Write-Output "  opencode said: $_" }
  exit 3
}

# 4. anything else (proxy down, binary missing, timeout, auth error...)
Write-Output "RESULT: NO VERDICT (exit $rc) -- last lines of output:"
$tail = @($output -split "`r?`n")
$start = [Math]::Max(0, $tail.Count - 5)
for ($i = $start; $i -lt $tail.Count; $i++) {
  Write-Output ("  " + $tail[$i])
}
exit 2
