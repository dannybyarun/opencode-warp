#Requires -Version 5.1
#
# run-tests.ps1 - offline regression tests for the Windows implementation.
#
# Nothing here talks to WARP or to opencode: every external command is a
# generated .ps1 stub. The suite runs on Windows PowerShell 5.1, PowerShell 7+
# on Windows, and PowerShell 7+ on Linux (with pwsh). That last combination is
# how the project's CI-friendly checks exercise the Windows scripts without a
# Windows host.
#
# Run from anywhere:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\run-tests.ps1
#   pwsh -NoProfile -File ./tests/windows/run-tests.ps1
#
# Set OPENCODE_WARP_KEEP_TESTS=1 to keep the temporary directory on failure.

$ErrorActionPreference = "Stop"

$TestsDir = Split-Path -Parent $PSCommandPath
$Root = Split-Path -Parent (Split-Path -Parent $TestsDir)
$Windows = Join-Path $Root "windows"
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("opencode-warp-win-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

$script:Pass = 0
$script:Fail = 0
$script:RC = 0

function Pass {
  param([string]$Label)
  $script:Pass++
  Write-Output ("ok   - " + $Label)
}

function Fail {
  param([string]$Label, [string]$Detail = "")
  $script:Fail++
  Write-Output ("FAIL - " + $Label)
  if ($Detail) {
    foreach ($line in ($Detail -split "`r?`n")) {
      Write-Output ("       " + $line)
    }
  }
}

function Check-Rc {
  param([int]$Want, [string]$Label, $Result)
  if ($Result.ExitCode -eq $Want) {
    Pass $Label
  } else {
    Fail $Label ("wanted rc $Want, got $($Result.ExitCode)`n--- stdout ---`n$($Result.Out)`n--- stderr ---`n$($Result.Err)")
  }
}

function Check-Contains {
  param([string]$Text, [string]$Pattern, [string]$Label)
  if ($Text -match $Pattern) {
    Pass $Label
  } else {
    Fail $Label ("missing /$Pattern/ in:`n" + $Text.Trim())
  }
}

function Check-NotContains {
  param([string]$Text, [string]$Pattern, [string]$Label)
  if ($Text -notmatch $Pattern) {
    Pass $Label
  } else {
    Fail $Label ("unexpected /$Pattern/ in:`n" + $Text.Trim())
  }
}

function Check-Equal {
  param($Actual, $Expected, [string]$Label)
  if ([string]$Actual -eq [string]$Expected) {
    Pass $Label
  } else {
    Fail $Label ("wanted [$Expected], got [$Actual]")
  }
}

function Read-Text {
  param([string]$Path)
  if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [IO.File]::ReadAllText($Path)
  }
  return ""
}

function Write-Mock {
  param([string]$Path, [string]$Body)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path, $Body, $encoding)
}

# --------------------------------------------------------------- test runner
$PS = $env:OPENCODE_WARP_POWERSHELL
if (-not $PS) {
  try { $PS = (Get-Process -Id $PID).Path } catch { $PS = $null }
}
if (-not $PS) { $PS = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1 }
if (-not $PS) { $PS = Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1 }
if (-not $PS) { throw "cannot find a PowerShell executable to run the child scripts" }
$env:OPENCODE_WARP_POWERSHELL = $PS

# Every test supplies its own isolated environment. Clear anything inherited
# from the caller so a developer's live WARP setup cannot influence a run.
$clean = @(
  "OPENCODE_WARP_HOME", "OPENCODE_WARP_STATE_DIR", "OPENCODE_WARP_PROBE",
  "OPENCODE_WARP_ROTATE", "OPENCODE_WARP_WARP_CLI", "OPENCODE_WARP_CURL",
  "OPENCODE_WARP_OPENCODE", "OPENCODE_WARP_LOG", "OPENCODE_WARP_CONFIG_DIR",
  "OPENCODE_CONFIG_DIR",
  "OPENCODE_WARP_NO_ROTATE", "OPENCODE_WARP_FORCE_PROBE", "OPENCODE_WARP_AUTO_ROTATE",
  "OPENCODE_WARP_ROTATE_STRICT", "OPCODE_REAL", "WARP_ROTATE_ATTEMPTS",
  "WARP_PROXY_PORT", "PROBE_RUN", "PROBE_MODEL", "PROBE_OUT", "PROBE_TIMEOUT",
  "PROBE_MODE", "PROBE_API_URL", "PROBE_API_KEY", "PROBE_HDR", "PROBE_DIRECT",
  "OPENCODE_RATELIMIT_LOG",
  "PROBE_SEQ", "PROBE_RCS", "CURL_SEQ", "CURL_RCS", "WARPTEST_LOG",
  "API_STATUS", "API_BODY", "API_RC",
  "OPENCODE_CALL_LOG", "ROTATE_LOG", "FAKE_ROTATE_RC", "FAKE_ROTATE_OUTPUT",
  "PROXY", "HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy",
  "NO_PROXY", "no_proxy", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
  "APPDATA", "LOCALAPPDATA"
)
foreach ($name in $clean) {
  [Environment]::SetEnvironmentVariable($name, $null, "Process")
}

function Invoke-Child {
  param(
    [Parameter(Mandatory = $true)][string]$Script,
    [string[]]$Arguments = @(),
    [hashtable]$Environment = @{}
  )

  $saved = @{}
  foreach ($key in $Environment.Keys) {
    $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
    [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
  }

  $outFile = Join-Path $Tmp ("out-" + [Guid]::NewGuid().ToString("N") + ".txt")
  $errFile = Join-Path $Tmp ("err-" + [Guid]::NewGuid().ToString("N") + ".txt")

  try {
    $global:LASTEXITCODE = 0
    & $PS -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 1> $outFile 2> $errFile
    $script:RC = $LASTEXITCODE
  } finally {
    foreach ($key in $saved.Keys) {
      [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process")
    }
  }

  return [pscustomobject]@{
    ExitCode = $script:RC
    Out      = Read-Text $outFile
    Err      = Read-Text $errFile
  }
}

# --------------------------------------------------------------- mock tools
$traceMock = Join-Path $Tmp "mock-curl.ps1"
Write-Mock $traceMock @'
$n = 0
if ($env:CURL_SEQ -and (Test-Path -LiteralPath $env:CURL_SEQ)) {
  $text = [IO.File]::ReadAllText($env:CURL_SEQ).Trim()
  if ($text) { $n = [int]$text }
}
$n = $n + 1
if ($env:CURL_SEQ) { [IO.File]::WriteAllText($env:CURL_SEQ, [string]$n) }

$rc = 0
if ($env:CURL_RCS -and (Test-Path -LiteralPath $env:CURL_RCS)) {
  $lines = [IO.File]::ReadAllLines($env:CURL_RCS)
  if ($n -le $lines.Count -and $lines[$n - 1].Trim()) { $rc = [int]$lines[$n - 1].Trim() }
}
if ($rc -ne 0) { exit $rc }

if ($args -match "cdn-cgi/trace") {
  Write-Output "ip=203.0.113.50"
  Write-Output "loc=US"
  Write-Output "warp=on"
} else {
  Write-Output "203.0.113.50"
}
exit 0
'@

# API-mode curl stub: writes a body and headers, then prints the status marker
# the probe parses. One response per process, driven by API_* env vars.
$apiCurlMock = Join-Path $Tmp "mock-api-curl.ps1"
Write-Mock $apiCurlMock @'
$out = ""
$hdr = ""
$fmt = ""
$i = 0
while ($i -lt $args.Count) {
  $a = [string]$args[$i]
  if ($a -ceq "-o") { $i++; $out = [string]$args[$i] }
  elseif ($a -ceq "-D") { $i++; $hdr = [string]$args[$i] }
  elseif ($a -ceq "-w") { $i++; $fmt = [string]$args[$i] }
  elseif ($a -ceq "-H" -or $a -ceq "-d" -or $a -ceq "-x" -or $a -ceq "--max-time") { $i++ }
  $i++
}

$status = "200"
if ($env:API_STATUS) { $status = $env:API_STATUS }
$body = ""
if ($env:API_BODY) { $body = $env:API_BODY }
$rc = 0
if ($env:API_RC) { $rc = [int]$env:API_RC }

$encoding = New-Object System.Text.UTF8Encoding($false)
if ($hdr) {
  [IO.File]::WriteAllText($hdr, "HTTP/1.1 $status`r`nretry-after: 120`r`ncf-ray: test-ray`r`n`r`n", $encoding)
}
if ($out) { [IO.File]::WriteAllText($out, $body, $encoding) }
if ($fmt) { Write-Output ("HTTPSTATUS:" + $status) }
if ($rc -eq 56) {
  [Console]::Error.WriteLine("curl: (56) Recv failure: Connection reset by peer")
}
exit $rc
'@

# ---------------------------------------------------------------- probe.ps1
$probe = Join-Path $Windows "probe.ps1"

function New-ProbeMock {
  param([string]$Name, [string]$Body)
  $path = Join-Path $Tmp ("probe-run-" + $Name + ".ps1")
  Write-Mock $path $Body
  return $path
}

$probeSuccess = New-ProbeMock "success" @'
Write-Output "PONG"
exit 0
'@

$probeThrottled = New-ProbeMock "throttled" @'
Write-Output "Error: Free usage limit reached"
exit 1
'@

$probeFreeMessages = New-ProbeMock "free-messages" @'
Write-Output "You've used today's free messages. They reset at 12:00 AM."
Write-Output "Upgrade to OpenCode Go -> /connect"
exit 1
'@

$probeHttp429 = New-ProbeMock "http429" @'
Write-Output "Error: request failed with HTTP status 429"
exit 1
'@

$probeTransport = New-ProbeMock "transport" @'
Write-Output "Error: Transport: ECONNRESET: The socket connection was closed unexpectedly."
Start-Sleep -Seconds 30
exit 0
'@

$probeAuth = New-ProbeMock "auth" @'
Write-Output "Error: unauthorized: invalid API key"
exit 1
'@

$probeHang = New-ProbeMock "hang" @'
Start-Sleep -Seconds 30
exit 0
'@

function Invoke-Probe {
  param(
    [string]$Runner,
    [int]$TimeoutSec = 20
  )
  $out = Join-Path $Tmp ("probe-" + [Guid]::NewGuid().ToString("N") + ".out")
  return Invoke-Child -Script $probe -Environment @{
    PROBE_RUN                = $Runner
    PROBE_OUT                = $out
    PROBE_TIMEOUT            = [string]$TimeoutSec
    PROXY                    = "http://127.0.0.1:1"
    OPENCODE_WARP_CURL       = $traceMock
    OPENCODE_WARP_POWERSHELL = $PS
    OPENCODE_RATELIMIT_LOG   = (Join-Path $Tmp "missing-ratelimit.jsonl")
  }
}

$result = Invoke-Probe $probeSuccess
Check-Rc 0 "probe: PONG is success" $result
Check-Contains $result.Out "RESULT: SUCCESS" "probe: success verdict printed"

$result = Invoke-Probe $probeThrottled
Check-Rc 1 "probe: 429 wording is throttled" $result
Check-Contains $result.Out "RESULT: THROTTLED" "probe: throttled verdict printed"

$result = Invoke-Probe $probeFreeMessages
Check-Rc 1 "probe: today's-free-messages notice is throttled" $result
Check-Contains $result.Out "RESULT: THROTTLED" "probe: free-messages verdict printed"

$result = Invoke-Probe $probeHttp429
Check-Rc 1 "probe: a bare HTTP 429 is throttled" $result
Check-Contains $result.Out "RESULT: THROTTLED" "probe: bare-429 verdict printed"

$started = Get-Date
$result = Invoke-Probe $probeTransport 20
$elapsed = ((Get-Date) - $started).TotalSeconds
Check-Rc 3 "probe: ECONNRESET is a transport failure" $result
Check-Contains $result.Out "RESULT: TRANSPORT FAILURE" "probe: transport verdict printed"
if ($elapsed -le 8) {
  Pass ("probe: socket error returns immediately ({0:N0}s)" -f $elapsed)
} else {
  Fail ("probe: socket error took {0:N0}s despite early kill" -f $elapsed)
}

$result = Invoke-Probe $probeAuth
Check-Rc 2 "probe: auth error remains no verdict" $result
Check-Contains $result.Out "RESULT: NO VERDICT" "probe: no-verdict wording preserved"

$started = Get-Date
$result = Invoke-Probe $probeHang 2
$elapsed = ((Get-Date) - $started).TotalSeconds
Check-Rc 2 "probe: silent hang remains no verdict" $result
Check-Contains $result.Out "RESULT: NO VERDICT" "probe: hang verdict printed"
if ($elapsed -le 10) {
  Pass ("probe: PROBE_TIMEOUT is honoured ({0:N0}s)" -f $elapsed)
} else {
  Fail ("probe: timeout took {0:N0}s" -f $elapsed)
}

# ------------------------------------------------------- probe.ps1 (API mode)
function Invoke-ProbeApi {
  param(
    [string]$Status = "200",
    [int]$CurlRc = 0,
    [string]$Body = "",
    [string]$Mode = "api"
  )
  $out = Join-Path $Tmp ("probe-api-" + [Guid]::NewGuid().ToString("N") + ".out")
  return Invoke-Child -Script $probe -Environment @{
    PROBE_MODE               = $Mode
    PROBE_API_URL            = "http://api.test/v1/chat/completions"
    PROBE_API_KEY            = "public"
    PROBE_MODEL              = "opencode/deepseek-v4.1-flash-free"
    PROBE_OUT                = $out
    PROBE_TIMEOUT            = "20"
    PROBE_DIRECT             = "1"
    OPENCODE_WARP_CURL       = $apiCurlMock
    OPENCODE_WARP_POWERSHELL = $PS
    OPENCODE_RATELIMIT_LOG   = (Join-Path $Tmp "missing-ratelimit.jsonl")
    API_STATUS               = $Status
    API_BODY                 = $Body
    API_RC                   = [string]$CurlRc
  }
}

$result = Invoke-ProbeApi -Body '{"choices":[{"message":{"content":"PONG"}}]}'
Check-Rc 0 "probe api: HTTP 200 is success" $result
Check-Contains $result.Out "RESULT: SUCCESS" "probe api: success verdict printed"
Check-Contains $result.Out "PONG" "probe api: PONG is reported"

$result = Invoke-ProbeApi -Body '{"choices":[{"message":{"content":"hello"}}]}'
Check-Rc 0 "probe api: HTTP 200 without PONG is still success" $result

$result = Invoke-ProbeApi -Status "429" -Body '{"error":{"type":"FreeUsageLimitError","message":"Free usage limit reached."}}'
Check-Rc 1 "probe api: HTTP 429 is throttled" $result
Check-Contains $result.Out "RESULT: THROTTLED" "probe api: throttled verdict printed"
Check-Contains $result.Out "HTTP 429" "probe api: HTTP status is reported"
Check-Contains $result.Out "unblocks" "probe api: retry-after is decoded"
Check-Contains $result.Out "test-ray" "probe api: cf-ray is reported"

$result = Invoke-ProbeApi -Status "403" -Body '{"error":{"message":"You have used today''s free messages."}}'
Check-Rc 1 "probe api: free-messages wording is throttled" $result

$result = Invoke-ProbeApi -Status "000" -CurlRc 56
Check-Rc 3 "probe api: curl reset is a transport failure" $result
Check-Contains $result.Out "RESULT: TRANSPORT FAILURE" "probe api: transport verdict printed"

$result = Invoke-ProbeApi -Status "000" -CurlRc 28
Check-Rc 2 "probe api: curl timeout remains no verdict" $result
Check-Contains $result.Out "RESULT: NO VERDICT" "probe api: timeout verdict printed"

$result = Invoke-ProbeApi -Status "401" -Body '{"error":{"message":"unauthorized"}}'
Check-Rc 2 "probe api: 401 remains no verdict" $result

$result = Invoke-ProbeApi -Status "500" -Body '{"error":"internal"}'
Check-Rc 2 "probe api: 500 remains no verdict" $result

$result = Invoke-ProbeApi -Body '{"choices":[{"message":{"content":"PONG"}}]}' -Mode "auto"
Check-Rc 0 "probe api: auto selects the API for opencode models" $result

# ----------------------------------------------------------- warp-rotate.ps1
$rotate = Join-Path $Windows "warp-rotate.ps1"

$fakeWarp = Join-Path $Tmp "fake-warp-cli.ps1"
Write-Mock $fakeWarp @'
$line = $args -join " "
if ($env:WARPTEST_LOG) {
  [IO.File]::AppendAllText($env:WARPTEST_LOG, $line + "`n")
}
if ($line -like "*status*") {
  if ($env:WARPTEST_STATUS) { Write-Output $env:WARPTEST_STATUS } else { Write-Output "Status update: Connected" }
  exit 0
}
if ($line -like "*settings*") {
  if ($env:WARPTEST_SETTINGS) { Write-Output $env:WARPTEST_SETTINGS } else { Write-Output "Mode: WarpProxy on port 40000" }
  exit 0
}
exit 0
'@

$fakeRotateProbe = Join-Path $Tmp "fake-probe.ps1"
Write-Mock $fakeRotateProbe @'
$seq = $env:PROBE_SEQ
$n = 0
if ($seq -and (Test-Path -LiteralPath $seq)) {
  $text = [IO.File]::ReadAllText($seq).Trim()
  if ($text) { $n = [int]$text }
}
$n = $n + 1
if ($seq) { [IO.File]::WriteAllText($seq, [string]$n) }

$rc = 2
if ($env:PROBE_RCS -and (Test-Path -LiteralPath $env:PROBE_RCS)) {
  $lines = [IO.File]::ReadAllLines($env:PROBE_RCS)
  if ($n -le $lines.Count -and $lines[$n - 1].Trim()) { $rc = [int]$lines[$n - 1].Trim() }
}

Write-Output "--- egress (WARP) ---"
Write-Output "ip=203.0.113.$n"
Write-Output "loc=US"
Write-Output "warp=on"
switch ($rc) {
  0 { Write-Output "RESULT: SUCCESS (exit 0) -> PONG" }
  1 { Write-Output "RESULT: THROTTLED (exit 1)" }
  3 { Write-Output "RESULT: TRANSPORT FAILURE (exit 3)" }
  default { Write-Output "RESULT: NO VERDICT (exit 2)" }
}
exit $rc
'@

function Invoke-Rotate {
  param(
    [string]$Rcs,
    [int]$Attempts = 2,
    [string[]]$Arguments = @(),
    [hashtable]$Extra = @{}
  )

  $caseDir = Join-Path $Tmp ("rotate-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
  $rcsPath = Join-Path $caseDir "probe-rcs"
  $seqPath = Join-Path $caseDir "probe-seq"
  $warpLog = Join-Path $caseDir "warp-cli.log"
  $stateDir = Join-Path $caseDir "state"
  [IO.File]::WriteAllText($rcsPath, $Rcs + "`n")
  [IO.File]::WriteAllText($seqPath, "")
  [IO.File]::WriteAllText($warpLog, "")

  $environment = @{
    OPENCODE_WARP_PROBE       = $fakeRotateProbe
    OPENCODE_WARP_WARP_CLI    = $fakeWarp
    OPENCODE_WARP_CURL        = $traceMock
    OPENCODE_WARP_STATE_DIR   = $stateDir
    OPENCODE_WARP_POWERSHELL  = $PS
    WARP_ROTATE_ATTEMPTS      = [string]$Attempts
    WARPTEST_LOG              = $warpLog
    PROBE_SEQ                 = $seqPath
    PROBE_RCS                 = $rcsPath
    CURL_SEQ                  = (Join-Path $caseDir "curl-seq")
    CURL_RCS                  = (Join-Path $caseDir "curl-rcs")
  }
  foreach ($key in $Extra.Keys) { $environment[$key] = $Extra[$key] }

  $result = Invoke-Child -Script $rotate -Arguments $Arguments -Environment $environment
  $result | Add-Member -NotePropertyName WarpLog -NotePropertyValue (Read-Text $warpLog)
  $result | Add-Member -NotePropertyName Sequence -NotePropertyValue (Read-Text $seqPath)
  $result | Add-Member -NotePropertyName StateDir -NotePropertyValue $stateDir
  return $result
}

$result = Invoke-Rotate "0"
Check-Rc 0 "rotate: healthy ingress needs no rotation" $result
Check-NotContains $result.WarpLog "registration new" "rotate: healthy ingress leaves registration alone"

$result = Invoke-Rotate "1`n0"
Check-Rc 0 "rotate: throttled then healthy recovers" $result
Check-Contains $result.WarpLog "registration new" "rotate: throttle creates a new registration"
Check-Contains $result.Err "recovered: the new ingress passes" "rotate: recovery is reported"

$result = Invoke-Rotate "3`n0"
Check-Rc 0 "rotate: transport failure then healthy recovers" $result
Check-Contains $result.Err "transport failure through WARP; rotating" "rotate: transport failure triggers rotation"

$result = Invoke-Rotate "3`n3`n3"
Check-Rc 1 "rotate: exhausted transport failures are not fatal" $result
Check-Contains $result.Err "still not passing after 2 rotation attempt" "rotate: neutral exhaustion message"
$count = ([regex]::Matches($result.WarpLog, "registration new")).Count
Check-Equal $count 2 "rotate: attempts are bounded"

$result = Invoke-Rotate "2"
Check-Rc 2 "rotate: preflight no verdict stays fatal" $result
Check-NotContains $result.WarpLog "registration new" "rotate: no verdict does not rotate"

$result = Invoke-Rotate "3`n2"
Check-Rc 2 "rotate: post-rotation no verdict stays fatal" $result
Check-Contains $result.Err "no verdict after rotation" "rotate: post-rotation no verdict is reported"

$result = Invoke-Rotate "1`n3`n0" 3
Check-Rc 0 "rotate: throttle, transport, then success recovers across attempts" $result

$result = Invoke-Rotate "0" 2 @("--force")
Check-Rc 0 "rotate: --force rotates a healthy ingress" $result
Check-Contains $result.WarpLog "registration new" "rotate: --force replaces the registration"
Check-Equal $result.Sequence.Trim() "1" "rotate: --force probes only after rotating"

$result = Invoke-Rotate "0" 2 @("--rotate-only")
Check-Rc 0 "rotate: --rotate-only verifies the proxy without a model probe" $result
Check-Contains $result.WarpLog "registration new" "rotate: --rotate-only replaces the registration"
Check-Equal $result.Sequence.Trim() "" "rotate: --rotate-only never runs the probe"
Check-Contains $result.Err "rotation complete" "rotate: --rotate-only reports completion"

$result = Invoke-Rotate "0" 2 @("--rotate-only") @{ WARPTEST_SETTINGS = "Mode: Warp" }
Check-Rc 2 "rotate: --rotate-only fails when WARP is not in proxy mode" $result
Check-Contains $result.Err "not in proxy mode" "rotate: --rotate-only names the proxy-mode failure"
Check-Contains $result.Err "could not restore a reachable WARP proxy" "rotate: --rotate-only reports the failed rotation"

$result = Invoke-Rotate "1`n0" 2 @() @{ WARPTEST_SETTINGS = "Mode: Warp" }
Check-Rc 2 "rotate: a non-proxy mode is refused" $result
Check-Contains $result.Err "not in proxy mode" "rotate: full-tunnel mode is named"
Check-Contains $result.WarpLog "disconnect" "rotate: full-tunnel mode is disconnected"

# ---------------------------------------------------------- opencode-warp.ps1
$wrapper = Join-Path $Windows "opencode-warp.ps1"

$fakeOpenCode = Join-Path $Tmp "fake-opencode.ps1"
Write-Mock $fakeOpenCode @'
$first = ""
if ($args.Count -gt 0) { $first = [string]$args[0] }
if ($first -eq "run" -and $args.Count -gt 1 -and [string]$args[1] -eq "--help") {
  Write-Output "opencode run --standalone"
  exit 0
}
if ($first -eq "--version") {
  Write-Output "opencode fake 9.9"
  exit 0
}
if ($env:OPENCODE_CALL_LOG) {
  $line = "proxy=" + $env:HTTPS_PROXY + "|no_proxy=" + $env:NO_PROXY + "|args=" + ($args -join " ")
  [IO.File]::AppendAllText($env:OPENCODE_CALL_LOG, $line + "`n")
}
Write-Output "FAKE_OPENCODE_OK"
exit 0
'@

$fakeNoStandalone = Join-Path $Tmp "fake-opencode-old.ps1"
Write-Mock $fakeNoStandalone @'
if ($args.Count -gt 0 -and [string]$args[0] -eq "run" -and $args.Count -gt 1 -and [string]$args[1] -eq "--help") {
  Write-Output "opencode run --help (no such flag)"
  exit 0
}
if ($args.Count -gt 0 -and [string]$args[0] -eq "--version") {
  Write-Output "opencode fake 0.1"
  exit 0
}
if ($env:OPENCODE_CALL_LOG) {
  $line = "proxy=" + $env:HTTPS_PROXY + "|no_proxy=" + $env:NO_PROXY + "|args=" + ($args -join " ")
  [IO.File]::AppendAllText($env:OPENCODE_CALL_LOG, $line + "`n")
}
Write-Output "FAKE_OPENCODE_OK"
exit 0
'@

$fakeRotate = Join-Path $Tmp "fake-rotate.ps1"
Write-Mock $fakeRotate @'
if ($env:ROTATE_LOG) { [IO.File]::AppendAllText($env:ROTATE_LOG, "rotate`n") }
if ($env:ROTATE_ENV_LOG) {
  $line = "PROBE_RUN=$($env:PROBE_RUN)`nPROBE_MODEL=$($env:PROBE_MODEL)`nPROBE_MODE=$($env:PROBE_MODE)`n"
  [IO.File]::WriteAllText($env:ROTATE_ENV_LOG, $line)
}
if ($env:FAKE_ROTATE_OUTPUT) { Write-Output $env:FAKE_ROTATE_OUTPUT }
$rc = 0
if ($env:FAKE_ROTATE_RC) { $rc = [int]$env:FAKE_ROTATE_RC }
exit $rc
'@

function Invoke-Wrapper {
  param(
    [int]$RotateRc = 0,
    [string]$CurlRcs = "0",
    [string]$Strict = "0",
    [string[]]$Arguments = @("--stand", "run", "-m", "opencode/deepseek-v4.1-flash-free", "hi"),
    [hashtable]$Extra = @{},
    [string]$OpenCode = $fakeOpenCode
  )

  $caseDir = Join-Path $Tmp ("wrap-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
  $callLog = Join-Path $caseDir "opencode.log"
  $rotateLog = Join-Path $caseDir "rotate.log"
  $rotateEnvLog = Join-Path $caseDir "rotate-env.log"
  [IO.File]::WriteAllText($callLog, "")
  [IO.File]::WriteAllText($rotateLog, "")
  [IO.File]::WriteAllText($rotateEnvLog, "")

  $environment = @{
    OPENCODE_WARP_OPENCODE    = $OpenCode
    OPENCODE_WARP_ROTATE      = $fakeRotate
    OPENCODE_WARP_CURL        = $traceMock
    OPENCODE_WARP_WARP_CLI    = (Join-Path $caseDir "missing-warp-cli.exe")
    OPENCODE_WARP_POWERSHELL  = $PS
    OPENCODE_WARP_STATE_DIR   = (Join-Path $caseDir "state")
    OPENCODE_WARP_FORCE_PROBE = "1"
    OPENCODE_WARP_ROTATE_STRICT = $Strict
    OPENCODE_CALL_LOG         = $callLog
    ROTATE_LOG                = $rotateLog
    ROTATE_ENV_LOG            = $rotateEnvLog
    PROBE_RUN                 = ""
    PROBE_MODEL               = ""
    PROBE_MODE                = ""
    FAKE_ROTATE_RC            = [string]$RotateRc
    CURL_SEQ                  = (Join-Path $caseDir "curl-seq")
    CURL_RCS                  = (Join-Path $caseDir "curl-rcs")
    XDG_DATA_HOME             = (Join-Path $caseDir "data")
    XDG_CONFIG_HOME           = (Join-Path $caseDir "config")
    APPDATA                   = (Join-Path $caseDir "appdata")
    LOCALAPPDATA              = (Join-Path $caseDir "local")
  }
  [IO.File]::WriteAllText($environment.CURL_RCS, $CurlRcs + "`n")
  foreach ($key in $Extra.Keys) {
    if ($key -eq "OPENCODE_WARP_FORCE_PROBE" -and $Extra[$key] -eq "") {
      $environment.Remove("OPENCODE_WARP_FORCE_PROBE") | Out-Null
      continue
    }
    $environment[$key] = $Extra[$key]
  }

  $result = Invoke-Child -Script $wrapper -Arguments $Arguments -Environment $environment
  $result | Add-Member -NotePropertyName Calls -NotePropertyValue (Read-Text $callLog)
  $result | Add-Member -NotePropertyName Rotations -NotePropertyValue (Read-Text $rotateLog)
  $result | Add-Member -NotePropertyName RotateEnv -NotePropertyValue (Read-Text $rotateEnvLog)
  $result | Add-Member -NotePropertyName CaseDir -NotePropertyValue $caseDir
  return $result
}

$result = Invoke-Wrapper
Check-Rc 0 "wrapper: healthy rotation starts opencode" $result
Check-Contains $result.Calls "standalone" "wrapper: --standalone still injected"
Check-Contains $result.Out "FAKE_OPENCODE_OK" "wrapper: opencode actually ran"
Check-Contains $result.Calls "proxy=http://127.0.0.1:40000" "wrapper: HTTPS_PROXY is injected"
Check-Contains $result.Calls "no_proxy=127.0.0.1,localhost" "wrapper: NO_PROXY is injected"
Check-NotContains $result.Calls "args=--stand " "wrapper: the --stand marker is stripped"
Check-Contains $result.Rotations "rotate" "wrapper: preflight consulted the rotator"
Check-Contains $result.RotateEnv "PROBE_MODE=cli" "wrapper: opencode models use the CLI probe"
Check-NotContains $result.RotateEnv "PROBE_RUN=." "wrapper: opencode models leave PROBE_RUN to probe.ps1"
Check-Contains $result.RotateEnv "PROBE_MODEL=opencode/deepseek-v4.1-flash-free" "wrapper: the free model is forwarded to the probe"

$result = Invoke-Wrapper -Arguments @("run", "-m", "openrouter/some-free-model", "hi")
Check-Rc 0 "wrapper: third-party free models still run" $result
Check-Contains $result.RotateEnv "PROBE_RUN=.*opencode-warp.ps1" "wrapper: third-party models force the CLI probe"
Check-Contains $result.RotateEnv "PROBE_MODEL=openrouter/some-free-model" "wrapper: the third-party model is forwarded"

$result = Invoke-Wrapper -RotateRc 2 -CurlRcs "0`n0"
Check-Rc 0 "wrapper: no verdict starts opencode when proxy is reachable" $result
Check-Contains $result.Err "could not get a model verdict" "wrapper: no-verdict warning printed"
Check-Contains $result.Err "starting opencode anyway" "wrapper: warning explains the fallback"
Check-Contains $result.Calls "standalone" "wrapper: fallback still uses WARP env"

$result = Invoke-Wrapper -RotateRc 2 -CurlRcs "0`n1"
Check-Rc 2 "wrapper: no verdict aborts when proxy is unreachable" $result
Check-Contains $result.Err "proxy is" "wrapper: proxy failure is named"
Check-NotContains $result.Calls "standalone" "wrapper: opencode does not run on a broken proxy"

$result = Invoke-Wrapper -RotateRc 2 -Strict 1 -CurlRcs "0`n0"
Check-Rc 2 "wrapper: strict mode keeps no verdict fatal" $result
Check-Contains $result.Err "OPENCODE_WARP_ROTATE_STRICT=1" "wrapper: strict mode is explained"

$result = Invoke-Wrapper -RotateRc 1 -CurlRcs "0"
Check-Rc 0 "wrapper: exhausted recovery still starts opencode" $result
Check-Contains $result.Err "did not produce a healthy ingress" "wrapper: neutral recovery warning"
Check-Contains $result.Calls "standalone" "wrapper: exhausted recovery still uses WARP"

$result = Invoke-Wrapper -RotateRc 1 -Strict 1 -CurlRcs "0"
Check-Rc 1 "wrapper: strict mode keeps exhausted recovery fatal" $result
Check-NotContains $result.Calls "standalone" "wrapper: strict exhaustion does not start opencode"

# `serve` is already a foreground server: WARP env, but no --standalone.
$result = Invoke-Wrapper -Arguments @("serve", "--port", "4096")
Check-Rc 0 "wrapper: serve starts opencode" $result
Check-Contains $result.Calls "args=serve --port 4096" "wrapper: serve args are passed through"
Check-NotContains $result.Calls "standalone" "wrapper: serve does not get --standalone"
Check-Contains $result.Calls "proxy=http://127.0.0.1:40000" "wrapper: serve gets the WARP env"
Check-Contains $result.Rotations "rotate" "wrapper: serve still runs the preflight"

$result = Invoke-Wrapper -CurlRcs "1`n1`n1" -Arguments @("serve", "--port", "4096")
Check-Rc 1 "wrapper: serve refuses a dead WARP proxy" $result
Check-NotContains $result.Calls "args=serve" "wrapper: serve does not run on a broken proxy"

$result = Invoke-Wrapper -OpenCode $fakeNoStandalone -Arguments @("serve", "--port", "4096")
Check-Rc 0 "wrapper: serve does not require run --standalone" $result
Check-Contains $result.Calls "args=serve --port 4096" "wrapper: serve still runs without the flag"

# `--server` points at a server that owns its own egress: pure passthrough.
$result = Invoke-Wrapper -Arguments @("run", "--server", "http://127.0.0.1:4096", "-m", "opencode/deepseek-v4.1-flash-free", "hi")
Check-Rc 0 "wrapper: --server is a passthrough" $result
Check-Contains $result.Calls "args=run --server http://127.0.0.1:4096 -m" "wrapper: --server args are passed through"
Check-NotContains $result.Calls "standalone" "wrapper: --server does not get --standalone"
Check-NotContains $result.Calls "proxy=http" "wrapper: --server does not get the proxy env"
Check-Equal $result.Rotations.Trim() "" "wrapper: --server skips the preflight"

$result = Invoke-Wrapper -Arguments @("api", "--server", "http://127.0.0.1:4096", "get", "/api/info")
Check-Rc 0 "wrapper: api --server is a passthrough" $result
Check-Contains $result.Calls "args=api --server http://127.0.0.1:4096 get /api/info" "wrapper: api args are passed through"
Check-NotContains $result.Calls "standalone" "wrapper: api --server does not get --standalone"
Check-Equal $result.Rotations.Trim() "" "wrapper: api --server skips the preflight"

$result = Invoke-Wrapper -OpenCode $fakeNoStandalone -Arguments @("--server=remote", "api", "get", "/api/info")
Check-Rc 0 "wrapper: --server=URL needs no --standalone" $result
Check-Contains $result.Calls "args=--server=remote api" "wrapper: --server=URL is passed through"

# Preflight policy: no log and no state means no probe at all.
$result = Invoke-Wrapper -Extra @{ OPENCODE_WARP_FORCE_PROBE = "" }
Check-Rc 0 "wrapper: no rate-limit evidence skips the preflight" $result
Check-Equal $result.Rotations.Trim() "" "wrapper: no evidence means no rotation"

# A recent rate-limit log line triggers the preflight without FORCE_PROBE.
$caseDir = Join-Path $Tmp ("logcase-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
$logPath = Join-Path $caseDir "opencode.log"
$stamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
[IO.File]::WriteAllText($logPath, "timestamp=$stamp level=ERROR message=`"Free usage limit reached`"`n")
$result = Invoke-Wrapper -Extra @{
  OPENCODE_WARP_FORCE_PROBE = ""
  OPENCODE_WARP_LOG = $logPath
}
Check-Rc 0 "wrapper: a logged rate limit triggers recovery" $result
Check-Contains $result.Rotations "rotate" "wrapper: logged rate limit rotated WARP"

# The TUI's "today's free messages" notice must trigger recovery too.
$freeLog = Join-Path $caseDir "free-messages.log"
[IO.File]::WriteAllText($freeLog, "timestamp=$stamp level=ERROR message=`"You've used today's free messages. They reset at 12:00 AM.`"`n")
$result = Invoke-Wrapper -Extra @{
  OPENCODE_WARP_FORCE_PROBE = ""
  OPENCODE_WARP_LOG = $freeLog
}
Check-Rc 0 "wrapper: today's-free-messages log triggers recovery" $result
Check-Contains $result.Rotations "rotate" "wrapper: free-message log rotated WARP"

# A successful rotation after that log writes last-ok, so the next launch skips
# the probe even though the old error is still in the log file.
$stateDir = Join-Path $result.CaseDir "state"
if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
}
[IO.File]::WriteAllText((Join-Path $stateDir "last-ok"), [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60))
$result = Invoke-Wrapper -Extra @{
  OPENCODE_WARP_FORCE_PROBE = ""
  OPENCODE_WARP_LOG = $logPath
  OPENCODE_WARP_STATE_DIR = $stateDir
}
Check-Rc 0 "wrapper: a newer successful ingress skips recovery" $result
Check-Equal $result.Rotations.Trim() "" "wrapper: last-ok suppresses the stale log"

# An explicit paid model disables the free-tier rotation.
$result = Invoke-Wrapper -Extra @{
  OPENCODE_WARP_FORCE_PROBE = ""
  OPENCODE_WARP_LOG = $logPath
} -Arguments @("run", "-m", "anthropic/claude-sonnet-4", "hi")
Check-Rc 0 "wrapper: paid models still run" $result
Check-Equal $result.Rotations.Trim() "" "wrapper: paid model skips free-tier rotation"

# --version and --help must not probe or rotate.
$result = Invoke-Wrapper -Extra @{
  OPENCODE_WARP_FORCE_PROBE = ""
  OPENCODE_WARP_LOG = $logPath
} -Arguments @("--version")
Check-Rc 0 "wrapper: --version passes through" $result
Check-Contains $result.Out "opencode fake 9.9" "wrapper: --version output is preserved"
Check-Equal $result.Rotations.Trim() "" "wrapper: --version skips the preflight"

# Startup proxy failure is fatal before any model call.
$result = Invoke-Wrapper -CurlRcs "1`n1`n1"
Check-Rc 1 "wrapper: an unreachable proxy aborts at startup" $result
Check-Contains $result.Err "WARP proxy unreachable" "wrapper: startup proxy failure is named"
Check-NotContains $result.Calls "standalone" "wrapper: no model call on a dead proxy"

# Older opencode without run --standalone must fail loudly.
$result = Invoke-Wrapper -OpenCode $fakeNoStandalone -Extra @{ OPENCODE_WARP_FORCE_PROBE = "" }
Check-Rc 1 "wrapper: missing --standalone is fatal" $result
Check-Contains $result.Err "no .run --standalone. flag" "wrapper: missing --standalone explained"
Check-NotContains $result.Calls "standalone" "wrapper: old opencode never runs through WARP"

# -------------------------------------------------------- profile management
. (Join-Path $Windows "common.ps1")

$profilePath = Join-Path $Tmp "profile.ps1"
$original = "# my profile`nSet-Variable editor vim`n"
[IO.File]::WriteAllText($profilePath, $original)
$changed = Install-ProfileBlock -Path $profilePath
$profileText = Read-Text $profilePath
if ($changed) { Pass "profile: the block is installed" } else { Fail "profile: installer reported no change" }
Check-Contains $profileText "opencode-warp shortcut" "profile: marked block present"
Check-Contains $profileText "Set-Variable editor vim" "profile: existing content preserved"
Check-Contains $profileText "function global:opencode" "profile: opencode function defined"

$again = Install-ProfileBlock -Path $profilePath
Check-Equal $again "False" "profile: installation is idempotent"
$count = ([regex]::Matches((Read-Text $profilePath), "# >>> opencode-warp shortcut >>>")).Count
Check-Equal $count 1 "profile: only one marked block"

$removed = Remove-ProfileBlock -Path $profilePath
$profileText = Read-Text $profilePath
if ($removed) { Pass "profile: the block is removed" } else { Fail "profile: remover reported no change" }
Check-NotContains $profileText "opencode-warp shortcut" "profile: marked block gone"
Check-Contains $profileText "Set-Variable editor vim" "profile: unrelated content survives removal"

Check-Equal (ConvertTo-QuotedArgument "two words") '"two words"' "arguments: spaces are quoted"
Check-Equal (ConvertTo-QuotedArgument "plain") "plain" "arguments: plain words stay unquoted"

Check-Equal (Get-OpenCodeMajorVersion "opencode v2.1.4") 2 "setup policy: 'opencode v2.1.4' is major 2"
Check-Equal (Get-OpenCodeMajorVersion "2.1.4") 2 "setup policy: a bare version is parsed"
Check-Equal (Get-OpenCodeMajorVersion "opencode v1.18.3") 1 "setup policy: OpenCode 1 is detected"
Check-Equal (Get-OpenCodeMajorVersion "v10.0.1") 10 "setup policy: multi-digit majors are parsed"
Check-Equal (Get-OpenCodeMajorVersion "unknown") 0 "setup policy: unknown versions count as 0"
Check-Equal (Get-OpenCodeMajorVersion "") 0 "setup policy: empty versions count as 0"

# OpenCode's own OPENCODE_CONFIG_DIR must win over the platform default, and
# the repo-specific override must win over both.
$env:XDG_CONFIG_HOME = Join-Path $Tmp "xdg"
Check-Equal (Get-OpenCodeConfigDir) (Join-Path $env:XDG_CONFIG_HOME "opencode") "config: XDG_CONFIG_HOME is honoured"
$env:OPENCODE_CONFIG_DIR = Join-Path $Tmp "opencode-config"
Check-Equal (Get-OpenCodeConfigDir) $env:OPENCODE_CONFIG_DIR "config: OPENCODE_CONFIG_DIR is honoured"
$env:OPENCODE_WARP_CONFIG_DIR = Join-Path $Tmp "warp-config"
Check-Equal (Get-OpenCodeConfigDir) $env:OPENCODE_WARP_CONFIG_DIR "config: OPENCODE_WARP_CONFIG_DIR wins"
$env:OPENCODE_WARP_CONFIG_DIR = $null
$env:OPENCODE_CONFIG_DIR = $null
$env:XDG_CONFIG_HOME = $null

# .cmd paths commonly contain spaces (%ProgramFiles%\nodejs\npm.cmd). cmd.exe
# /s /c needs the quoted path wrapped in one extra pair of quotes.
$spaceCmd = Join-Path $Tmp "dir with spaces\fake.cmd"
$cmdLine = Get-ExternalCommandLine -Path $spaceCmd -Arguments @("--rotate-only")
$wantCmd = "cmd.exe"
if ($env:ComSpec) { $wantCmd = $env:ComSpec }
Check-Equal $cmdLine.FilePath $wantCmd "arguments: .cmd runs through cmd.exe"
Check-Equal $cmdLine.Arguments ('/d /s /c ""' + $spaceCmd + '" --rotate-only"') "arguments: .cmd path with spaces is protected"

$spacePs1 = Join-Path $Tmp "dir with spaces\fake.ps1"
$psLine = Get-ExternalCommandLine -Path $spacePs1 -Arguments @("--flag", "two words")
Check-Contains $psLine.Arguments '-File ".*fake.ps1"' "arguments: .ps1 is run through PowerShell"
Check-Contains $psLine.Arguments '"two words"' "arguments: .ps1 arguments are quoted"

# ------------------------------------------------------ syntax / packaging
$scriptFiles = @(Get-ChildItem -LiteralPath $Windows -Filter "*.ps1" -File | Sort-Object Name)
$parseFailures = 0
foreach ($file in $scriptFiles) {
  $tokens = $null
  $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
  if ($errors.Count -eq 0) {
    Pass ("syntax: " + $file.Name + " parses")
  } else {
    $parseFailures++
    foreach ($error in $errors) {
      Fail ("syntax: " + $file.Name + ":" + $error.Extent.StartLineNumber) $error.Message
    }
  }
}
if ($parseFailures -eq 0) { Pass "syntax: every Windows script parses" }

# Windows PowerShell 5.1 has no null-coalescing operators and no parallel
# pipelines. A pwsh parse will not reject them, so scan for them explicitly.
$incompatible = 0
foreach ($file in $scriptFiles) {
  $text = [IO.File]::ReadAllText($file.FullName)
  $patterns = @("\?\?", "\?\.", '\$IsWindows', "-Parallel", "ConvertFrom-Json[^\r\n]*-AsHashtable")
  foreach ($pattern in $patterns) {
    if ($text -match $pattern) {
      $incompatible++
      Fail ("compat: " + $file.Name) ("uses a PowerShell 7-only construct: /" + $pattern + "/")
    }
  }
}
if ($incompatible -eq 0) { Pass "compat: no PowerShell 7-only constructs in windows/*.ps1" }

$required = @(
  "common.ps1", "probe.ps1", "warp-rotate.ps1", "opencode-warp.ps1",
  "setup.ps1", "uninstall.ps1", "opencode-warp.cmd", "opencode-stand.cmd",
  "probe.cmd", "warp-rotate.cmd"
)
foreach ($name in $required) {
  if (Test-Path -LiteralPath (Join-Path $Windows $name) -PathType Leaf) {
    Pass ("package: " + $name + " exists")
  } else {
    Fail ("package: " + $name + " exists") "missing file"
  }
}

$cmdChecks = @(
  @{ File = "opencode-warp.cmd"; Pattern = 'opencode-warp\.ps1' },
  @{ File = "opencode-stand.cmd"; Pattern = 'opencode-warp\.cmd' },
  @{ File = "probe.cmd"; Pattern = 'probe\.ps1' },
  @{ File = "warp-rotate.cmd"; Pattern = 'warp-rotate\.ps1' }
)
foreach ($check in $cmdChecks) {
  $text = Read-Text (Join-Path $Windows $check.File)
  Check-Contains $text "%~dp0" ("shim: " + $check.File + " is location independent")
  Check-Contains $text $check.Pattern ("shim: " + $check.File + " calls the right helper")
}

$setup = Join-Path $Windows "setup.ps1"
$result = Invoke-Child -Script $setup -Arguments @("-ValidateOnly")
Check-Rc 0 "setup: -ValidateOnly passes" $result
Check-Contains $result.Out "validation ok" "setup: validation reports success"
Check-Contains $result.Out "ok   - uninstall.ps1" "setup: uninstaller is installed with the helpers"

$setupText = Read-Text $setup
Check-Contains $setupText "Get-OpenCodeMajorVersion" "setup policy: the parsed major version is used"
Check-Contains $setupText "FreshInstall" "setup policy: fresh installs are tracked"
Check-Contains $setupText "not OpenCode 2" "setup policy: a fresh OpenCode 1 install fails"
Check-Contains $setupText "upgrade --major" "setup policy: an existing OpenCode 1 gets upgrade advice"

$uninstall = Join-Path $Windows "uninstall.ps1"
$uninstallText = Read-Text $uninstall
Check-Contains $uninstallText "-Purge" "uninstall: purge switch is documented"
Check-Contains $uninstallText "Remove-ProfileBlock" "uninstall: profile block is removed"
Check-Contains $uninstallText "Remove-UserPath" "uninstall: PATH entry is removed"

# ---------------------------------------------------------------- summary
Write-Output ""
Write-Output ("{0} passed, {1} failed" -f $script:Pass, $script:Fail)

if ($script:Fail -eq 0 -or -not $env:OPENCODE_WARP_KEEP_TESTS) {
  Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Write-Output ("temporary files kept at " + $Tmp)
}

if ($script:Fail -gt 0) { exit 1 }
exit 0
