#Requires -Version 5.1
#
# probe.ps1 - one-shot verdict for the WARP path (Windows).
#
# Reports the current WARP egress, fires exactly ONE model request and prints
# SUCCESS / THROTTLED / TRANSPORT FAILURE / NO VERDICT. It never loops or
# retries.
#
# By default the request goes straight to the same OpenAI-compatible endpoint
# OpenCode uses (https://opencode.ai/inference/openai/v1) with the public
# free-tier credential. That avoids creating an OpenCode session and does not
# depend on the `run` subcommand or the `--standalone` flag. Set PROBE_MODE=cli
# (or PROBE_RUN) to probe through `opencode run` instead.
#
# The raw API path can be gated for free models: it does not send the real
# OpenCode system prompt/tool payload, so it may return 429 even when the CLI
# succeeds on the same egress. The rotation helpers therefore default to
# PROBE_MODE=cli. Use API mode for endpoint/transport checks, not as proof
# that the TUI will fail.
#
# Exit codes:  0 = success
#              1 = throttled (429 / free-tier quota)
#              2 = no verdict (missing binary, auth error, timeout...)
#              3 = transport failure through WARP (ECONNRESET and friends)
#
# Overrides:   PROBE_MODE     api | cli | auto (default: auto; rotation helpers set cli)
#              PROBE_API_URL  chat-completions endpoint
#              PROBE_API_KEY  bearer token (default: public)
#              PROBE_RUN      command/script to run in CLI mode (default: opencode-warp.ps1)
#              PROBE_MODEL    model id (default: opencode/deepseek-v4.1-flash-free)
#              PROXY          proxy url (default: WARP; set PROBE_DIRECT=1 for direct API mode)
#              PROBE_TIMEOUT  seconds before giving up (default 45)
#              PROBE_OUT      capture file
#
# This script is deliberately one-shot: never let the wrapper it launches run
# its own preflight rotation, which would recurse. API mode does not launch
# opencode, but keep the guard for CLI mode and backwards compatibility.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# This process exists only to test the ingress.
$env:OPENCODE_WARP_NO_ROTATE = "1"

$port = "40000"
if ($env:WARP_PROXY_PORT) { $port = $env:WARP_PROXY_PORT }

$proxy = $env:PROXY
if ($null -eq $proxy) { $proxy = "http://127.0.0.1:$port" }
if ($env:PROBE_DIRECT -eq "1") { $proxy = "" }

$model = $env:PROBE_MODEL
if (-not $model) { $model = "opencode/deepseek-v4.1-flash-free" }

$mode = $env:PROBE_MODE
if ($mode -notin @("api", "cli")) { $mode = "auto" }

$apiUrl = $env:PROBE_API_URL
if (-not $apiUrl) { $apiUrl = "https://opencode.ai/inference/openai/v1/chat/completions" }
$apiKey = $env:PROBE_API_KEY
if (-not $apiKey) { $apiKey = "public" }

if ($mode -eq "auto") {
  if ($env:PROBE_RUN) {
    $mode = "cli"
  } elseif ($env:PROBE_API_URL) {
    $mode = "api"
  } elseif ($model -like "opencode/*") {
    $mode = "api"
  } else {
    $mode = "cli"
  }
}

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

$headerFile = $env:PROBE_HDR
if (-not $headerFile) { $headerFile = $outFile + ".headers" }

$log = $env:OPENCODE_RATELIMIT_LOG
if (-not $log) { $log = Join-Path (Get-OpenCodeDataDir) "ratelimit-retry.jsonl" }

$transportPattern = "ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENETUNREACH|EHOSTUNREACH|socket connection was closed|fetch failed|connection reset by peer|recv failure|send failure|connection refused|could not connect"
$throttlePattern = "rate limit exceeded|free usage limit reached|freeusagelimiterror|free messages|too many requests"
# The API mode learns the status from curl, so a bare "429" in the body is not
# needed there. CLI output has no status field, and OpenCode can print just
# "HTTP 429"; match that too, like probe.sh.
$cliThrottlePattern = $throttlePattern + "|429"

function Write-Egress {
  if ($proxy) {
    Write-Output "--- egress (WARP) ---"
    foreach ($line in (Get-EgressTrace -Proxy $proxy)) {
      Write-Output $line
    }
  } else {
    Write-Output "--- egress (direct) ---"
    Write-Output "  (PROXY is empty)"
  }
}

# Print the plugin log's unblock estimate when it has a fresh 429. This is
# best-effort: the verdict never depends on the log file.
function Write-LogHint {
  if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return }

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

function Get-ProbeCurl {
  $curl = $env:OPENCODE_WARP_CURL
  if ($curl -and -not (Test-Path -LiteralPath $curl -PathType Leaf)) { $curl = $null }
  if (-not $curl) {
    $curl = Get-CommandPath "curl.exe"
    if (-not $curl) { $curl = Get-CommandPath "curl" }
  }
  return $curl
}

function Get-HeaderValue {
  param([string]$Name)
  if (-not (Test-Path -LiteralPath $headerFile -PathType Leaf)) { return "" }
  $text = Read-TextFile $headerFile
  $found = [regex]::Matches($text, ("(?im)^" + [regex]::Escape($Name) + ":\s*(\S+)"))
  if ($found.Count -gt 0) {
    return $found[$found.Count - 1].Groups[1].Value.Trim()
  }
  return ""
}

function Invoke-ApiProbe {
  $apiModel = $model
  if ($apiModel -like "opencode/*") { $apiModel = $apiModel.Substring("opencode/".Length) }
  $hash = $apiModel.IndexOf("#")
  if ($hash -ge 0) { $apiModel = $apiModel.Substring(0, $hash) }

  $payload = @{
    model      = $apiModel
    messages   = @(@{ role = "user"; content = "reply with exactly: PONG" })
    max_tokens = 16
    stream     = $false
  } | ConvertTo-Json -Depth 5 -Compress

  Write-Egress
  Write-Output "--- one request through WARP ---"

  [IO.File]::WriteAllText($outFile, "")
  [IO.File]::WriteAllText($headerFile, "")

  $curl = Get-ProbeCurl
  if (-not $curl) {
    Write-Output "RESULT: NO VERDICT -- cannot find curl (set OPENCODE_WARP_CURL)"
    exit 2
  }

  $curlArgs = @("-sS", "--max-time", [string]$timeout)
  if ($proxy) { $curlArgs += @("-x", $proxy) }
  $curlArgs += @(
    "-D", $headerFile,
    "-o", $outFile,
    "-w", "HTTPSTATUS:%{http_code}",
    "-H", "Authorization: Bearer $apiKey",
    "-H", "Content-Type: application/json",
    "-d", $payload,
    $apiUrl
  )

  $result = Invoke-ScriptCaptured -ScriptPath $curl -Arguments $curlArgs
  $rc = $result.ExitCode
  $status = "000"
  $statusMatch = [regex]::Match($result.Output, "HTTPSTATUS:(\d{3})")
  if ($statusMatch.Success) { $status = $statusMatch.Groups[1].Value }

  $body = Read-TextFile $outFile
  $output = $body + "`n" + $result.Output

  if ($status -eq "200") {
    if ($body -cmatch "PONG") {
      Write-Output "RESULT: SUCCESS (HTTP 200) -> PONG"
    } else {
      Write-Output "RESULT: SUCCESS (HTTP 200)"
    }
    exit 0
  }

  # 429 is the shared free bucket. Match the API's own wording as well, in
  # case a proxy or future server returns the limit with another status.
  if ($status -eq "429" -or $output -imatch $throttlePattern) {
    Write-Output "RESULT: THROTTLED (HTTP $status)"

    try {
      $parsed = $body | ConvertFrom-Json
      if ($parsed.error) {
        $parts = @()
        if ($parsed.error.type) { $parts += [string]$parsed.error.type }
        if ($parsed.error.message) { $parts += [string]$parsed.error.message }
        if ($parts.Count -gt 0) { Write-Output ("  api said: " + ($parts -join ": ")) }
      }
    } catch {
      # The status already decided the verdict; the body is optional detail.
    }

    $retry = Get-HeaderValue "retry-after"
    $retrySeconds = 0
    if ([int]::TryParse($retry, [ref]$retrySeconds) -and $retrySeconds -gt 0) {
      $deadline = [DateTimeOffset]::UtcNow.AddSeconds($retrySeconds).ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
      Write-Output "  unblocks   : $deadline"
    }
    $cfray = Get-HeaderValue "cf-ray"
    if ($cfray) { Write-Output "  cf-ray     : $cfray" }

    Write-Output "  hint       : free quota is per model; raw API mode can be gated, so try PROBE_MODE=cli or /models"
    Write-LogHint
    exit 1
  }

  if ($output -imatch $transportPattern) {
    Write-Output "RESULT: TRANSPORT FAILURE (HTTP $status) -- the connection through WARP died:"
    @($output -split "`r?`n" | Where-Object { $_ -imatch $transportPattern } |
        Select-Object -First 2) | ForEach-Object { Write-Output "  curl said: $_" }
    exit 3
  }

  if ($rc -in @(7, 35, 52, 55, 56)) {
    Write-Output "RESULT: TRANSPORT FAILURE (curl exit $rc) -- the connection through WARP died:"
    $tail = @($output -split "`r?`n")
    $start = [Math]::Max(0, $tail.Count - 2)
    for ($i = $start; $i -lt $tail.Count; $i++) {
      Write-Output ("  curl said: " + $tail[$i])
    }
    exit 3
  }

  Write-Output "RESULT: NO VERDICT (HTTP $status, curl exit $rc) -- last lines of output:"
  $tail = @($output -split "`r?`n")
  $start = [Math]::Max(0, $tail.Count - 5)
  for ($i = $start; $i -lt $tail.Count; $i++) {
    Write-Output ("  " + $tail[$i])
  }
  exit 2
}

function Invoke-CliProbe {
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

  Write-Egress
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

  # 2. throttled: match opencode's own wording, not any plugin's bookkeeping.
  #    "Free usage limit reached" is the daily-free-tier text; the TUI may
  #    instead say "You've used today's free messages" - both mean the shared
  #    bucket is empty for you now.
  if ($output -imatch $cliThrottlePattern) {
    Write-Output "RESULT: THROTTLED (exit $rc)"
    @($output -split "`r?`n" | Where-Object {
        $_ -imatch $cliThrottlePattern
      } | Select-Object -First 2) | ForEach-Object { Write-Output "  opencode said: $_" }

    Write-Output "  hint       : free quota is per model; if rotation did not help, switch models with /models"
    Write-LogHint
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
}

if ($mode -eq "api") {
  Invoke-ApiProbe
} else {
  Invoke-CliProbe
}
