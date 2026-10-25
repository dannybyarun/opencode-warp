#Requires -Version 5.1
#
# common.ps1 - shared helpers for the Windows implementation.
#
# This file is dot-sourced by probe.ps1, warp-rotate.ps1, opencode-warp.ps1,
# setup.ps1 and uninstall.ps1. It deliberately sticks to Windows PowerShell
# 5.1 syntax so the tools work on a stock Windows 10/11 install.
#
# Every external command is invoked through Invoke-Captured, which redirects
# stdout/stderr to temporary files and returns the exit code. That keeps the
# scripts easy to exercise with stubbed helpers (see tests/windows).

$script:OpenCodeWarpCommonLoaded = $true

function Test-IsWindows {
  if ($env:OS -eq "Windows_NT") { return $true }
  return ([IO.Path]::DirectorySeparatorChar -eq [char]'\')
}

function Get-UserHome {
  if ($HOME) { return $HOME }
  $profileDir = [Environment]::GetFolderPath("UserProfile")
  if ($profileDir) { return $profileDir }
  return $env:USERPROFILE
}

function Get-OpenCodeWarpHome {
  if ($env:OPENCODE_WARP_HOME) { return $env:OPENCODE_WARP_HOME }
  $local = $env:LOCALAPPDATA
  if (-not $local) { $local = Join-Path (Get-UserHome) "AppData\Local" }
  return (Join-Path $local "opencode-warp")
}

function Get-OpenCodeWarpPaths {
  $homeDir = Get-OpenCodeWarpHome
  $state = $env:OPENCODE_WARP_STATE_DIR
  if (-not $state) { $state = Join-Path $homeDir "state" }
  return [pscustomobject]@{
    Home    = $homeDir
    Bin     = (Join-Path $homeDir "bin")
    State   = $state
    OpenCode = (Join-Path $homeDir "opencode")
  }
}

function Get-OpenCodeConfigDir {
  if ($env:OPENCODE_WARP_CONFIG_DIR) { return $env:OPENCODE_WARP_CONFIG_DIR }
  if ($env:OPENCODE_CONFIG_DIR) { return $env:OPENCODE_CONFIG_DIR }
  if ($env:XDG_CONFIG_HOME) { return (Join-Path $env:XDG_CONFIG_HOME "opencode") }
  $xdg = Join-Path (Get-UserHome) ".config\opencode"
  $appData = $null
  if ($env:APPDATA) { $appData = Join-Path $env:APPDATA "opencode" }
  if (Test-Path -LiteralPath $xdg -PathType Container) { return $xdg }
  if ($appData -and (Test-Path -LiteralPath $appData -PathType Container)) { return $appData }
  return $xdg
}

function Get-OpenCodeDataDir {
  if ($env:XDG_DATA_HOME) { return (Join-Path $env:XDG_DATA_HOME "opencode") }
  return (Join-Path (Get-UserHome) ".local\share\opencode")
}

function Write-Say {
  param([string]$Message)
  [Console]::Error.WriteLine("opencode-warp: $Message")
}

function Write-Warn {
  param([string]$Message)
  [Console]::Error.WriteLine("opencode-warp: warning: $Message")
}

function Write-Die {
  param([string]$Message, [int]$Code = 1)
  [Console]::Error.WriteLine("opencode-warp: $Message")
  exit $Code
}

function Test-IsAdministrator {
  if (-not (Test-IsWindows)) { return ($env:USER -eq "root") }
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Get-CommandPath {
  param([string]$Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandType -eq "Application" -or $_.CommandType -eq "ExternalScript" } |
    Select-Object -First 1
  if ($cmd) { return $cmd.Source }
  return $null
}

function Find-WarpCli {
  if ($env:OPENCODE_WARP_WARP_CLI) {
    if (Test-Path -LiteralPath $env:OPENCODE_WARP_WARP_CLI -PathType Leaf) {
      return $env:OPENCODE_WARP_WARP_CLI
    }
    return $null
  }

  $fromPath = Get-CommandPath "warp-cli.exe"
  if (-not $fromPath) { $fromPath = Get-CommandPath "warp-cli" }
  if ($fromPath) { return $fromPath }

  $candidates = @()
  if ($env:ProgramFiles) {
    $candidates += (Join-Path $env:ProgramFiles "Cloudflare\Cloudflare WARP\warp-cli.exe")
  }
  if (${env:ProgramFiles(x86)}) {
    $candidates += (Join-Path ${env:ProgramFiles(x86)} "Cloudflare\Cloudflare WARP\warp-cli.exe")
  }
  if ($env:LOCALAPPDATA) {
    $candidates += (Join-Path $env:LOCALAPPDATA "Cloudflare\Cloudflare WARP\warp-cli.exe")
  }
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  return $null
}

function Find-OpenCode {
  $override = $env:OPENCODE_WARP_OPENCODE
  if (-not $override) { $override = $env:OPCODE_REAL }
  if ($override) {
    if (Test-Path -LiteralPath $override -PathType Leaf) { return $override }
    return $null
  }

  $paths = Get-OpenCodeWarpPaths
  $fromPath = Get-CommandPath "opencode.exe"
  if (-not $fromPath) { $fromPath = Get-CommandPath "opencode.cmd" }
  if (-not $fromPath) { $fromPath = Get-CommandPath "opencode" }
  if ($fromPath -and $fromPath -notlike "*opencode-warp*") { return $fromPath }

  $candidates = @()
  $homeDir = Get-UserHome
  if ($homeDir) {
    $candidates += (Join-Path $homeDir ".opencode\bin\opencode.exe")
    $candidates += (Join-Path $homeDir ".opencode\bin\opencode.cmd")
  }
  if ($paths.OpenCode) {
    $candidates += (Join-Path $paths.OpenCode "opencode.exe")
    $candidates += (Join-Path $paths.OpenCode "opencode.cmd")
  }
  if ($env:LOCALAPPDATA) {
    $candidates += (Join-Path $env:LOCALAPPDATA "Programs\opencode\opencode.exe")
    $candidates += (Join-Path $env:LOCALAPPDATA "opencode\opencode.exe")
  }
  if ($env:APPDATA) {
    $candidates += (Join-Path $env:APPDATA "npm\opencode.cmd")
  }
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  return $null
}

function Find-OpenCodeLog {
  if ($env:OPENCODE_WARP_LOG -and (Test-Path -LiteralPath $env:OPENCODE_WARP_LOG -PathType Leaf)) {
    return $env:OPENCODE_WARP_LOG
  }
  $candidates = @(
    (Join-Path (Get-OpenCodeDataDir) "log\opencode.log")
  )
  if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA "opencode\log\opencode.log") }
  if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "opencode\log\opencode.log") }
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  return $null
}

function Get-OpenCodeVersion {
  param([string]$OpenCodePath)
  if (-not $OpenCodePath) { return "unknown" }
  $r = Invoke-ScriptCaptured -ScriptPath $OpenCodePath -Arguments @("--version")
  $line = ($r.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
  if ($line) { return $line.Trim() }
  return "unknown"
}

function Get-OpenCodeMajorVersion {
  param([string]$Version)
  if (-not $Version) { return 0 }
  # "opencode v2.1.4" and "2.1.4" both mean 2. Anything unparseable counts as
  # 0, so an unknown version is treated like OpenCode 1 instead of passing.
  $token = ($Version.Trim() -split '\s+')[-1]
  $token = $token -replace '^[vV]', ''
  if ($token -match '^(\d+)') {
    $major = 0
    if ([int]::TryParse($Matches[1], [ref]$major)) { return $major }
  }
  return 0
}

function Test-OpenCodeStandalone {
  param([string]$OpenCodePath)
  if (-not $OpenCodePath) { return $false }
  $r = Invoke-ScriptCaptured -ScriptPath $OpenCodePath -Arguments @("run", "--help")
  return ($r.Output -match "--standalone")
}

function Get-PowerShellExe {
  if ($env:OPENCODE_WARP_POWERSHELL) { return $env:OPENCODE_WARP_POWERSHELL }
  if (Test-IsWindows) {
    $ps = Get-CommandPath "powershell.exe"
    if ($ps) { return $ps }
    $ps = Get-CommandPath "pwsh.exe"
    if ($ps) { return $ps }
  } else {
    try {
      $current = (Get-Process -Id $PID).Path
      if ($current) { return $current }
    } catch {
      # fall through
    }
    $ps = Get-CommandPath "pwsh"
    if ($ps) { return $ps }
  }
  throw "cannot find a PowerShell executable"
}

function ConvertTo-QuotedArgument {
  param([string]$Argument)
  if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
  if ($Argument -notmatch '[\s"]') { return $Argument }

  $builder = New-Object System.Text.StringBuilder
  [void]$builder.Append('"')
  $backslashes = 0
  foreach ($ch in $Argument.ToCharArray()) {
    if ($ch -eq [char]'\') {
      $backslashes++
      continue
    }
    if ($ch -eq [char]'"') {
      [void]$builder.Append('\' * (($backslashes * 2) + 1))
      [void]$builder.Append('"')
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) {
      [void]$builder.Append('\' * $backslashes)
      $backslashes = 0
    }
    [void]$builder.Append($ch)
  }
  if ($backslashes -gt 0) {
    [void]$builder.Append('\' * ($backslashes * 2))
  }
  [void]$builder.Append('"')
  return $builder.ToString()
}

function Get-ExternalInvocation {
  param([string]$Path)
  $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($extension -eq ".ps1") {
    return [pscustomobject]@{
      Kind       = "ps1"
      FilePath   = (Get-PowerShellExe)
      PrefixArgs = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $Path)
    }
  }
  if ($extension -eq ".cmd" -or $extension -eq ".bat") {
    $comspec = $env:ComSpec
    if (-not $comspec) { $comspec = "cmd.exe" }
    return [pscustomobject]@{
      Kind       = "cmd"
      FilePath   = $comspec
      PrefixArgs = @("/d", "/s", "/c")
    }
  }
  return [pscustomobject]@{ Kind = "exe"; FilePath = $Path; PrefixArgs = @() }
}

function ConvertTo-ArgumentString {
  param([string[]]$Arguments = @())
  $pieces = @()
  foreach ($argument in $Arguments) {
    $pieces += (ConvertTo-QuotedArgument ([string]$argument))
  }
  return ($pieces -join " ")
}

function Get-ExternalCommandLine {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string[]]$Arguments = @()
  )
  $invocation = Get-ExternalInvocation $Path
  if ($invocation.Kind -eq "cmd") {
    # cmd.exe /s /c strips the first and last quote. Wrapping the quoted script
    # path in one extra pair keeps paths such as
    #   C:\Program Files\nodejs\npm.cmd
    # intact while still forwarding quoted arguments.
    $inner = ConvertTo-ArgumentString $Arguments
    $raw = '/d /s /c ""' + $Path + '"'
    if ($inner) { $raw += " " + $inner }
    $raw += '"'
    return [pscustomobject]@{ FilePath = $invocation.FilePath; Arguments = $raw }
  }

  $all = @($invocation.PrefixArgs) + @($Arguments)
  return [pscustomobject]@{
    FilePath  = $invocation.FilePath
    Arguments = (ConvertTo-ArgumentString $all)
  }
}

function Read-TextFile {
  param([string]$Path)
  try {
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
      return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    }
  } catch {
    # unreadable output is treated as empty
  }
  return ""
}

function Stop-ProcessTree {
  param($Process)
  if (-not $Process) { return }
  if (Test-IsWindows) {
    $null = Invoke-Captured -FilePath "taskkill.exe" -Arguments @("/PID", [string]$Process.Id, "/T", "/F")
  } else {
    try { Stop-Process -Id $Process.Id -Force -ErrorAction Stop } catch { }
  }
}

function Invoke-Captured {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [hashtable]$Environment = @{},
    [int]$TimeoutSec = 0,
    [string]$RawArguments = $null
  )

  $outFile = [IO.Path]::GetTempFileName()
  $errFile = [IO.Path]::GetTempFileName()
  $saved = @{}

  try {
    foreach ($key in $Environment.Keys) {
      $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
      [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
    }

    $argumentString = $RawArguments
    if ($null -eq $argumentString) {
      $argumentString = ConvertTo-ArgumentString $Arguments
    }

    $startArgs = @{
      FilePath               = $FilePath
      PassThru               = $true
      RedirectStandardOutput = $outFile
      RedirectStandardError  = $errFile
    }
    if ($argumentString) { $startArgs.ArgumentList = $argumentString }
    if (Test-IsWindows) { $startArgs.WindowStyle = "Hidden" }

    $process = Start-Process @startArgs
    if ($TimeoutSec -gt 0) {
      if (-not $process.WaitForExit($TimeoutSec * 1000)) {
        Stop-ProcessTree $process
        $null = $process.WaitForExit(5000)
        $text = (Read-TextFile $outFile) + (Read-TextFile $errFile) + "`n[timed out]"
        return [pscustomobject]@{ ExitCode = 124; Output = $text }
      }
    } else {
      $process.WaitForExit()
    }

    $code = $process.ExitCode
    $text = (Read-TextFile $outFile) + (Read-TextFile $errFile)
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
  } catch {
    return [pscustomobject]@{ ExitCode = 127; Output = $_.Exception.Message }
  } finally {
    foreach ($key in $saved.Keys) {
      [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process")
    }
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-ScriptCaptured {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [string[]]$Arguments = @(),
    [hashtable]$Environment = @{},
    [int]$TimeoutSec = 0
  )
  $commandLine = Get-ExternalCommandLine -Path $ScriptPath -Arguments $Arguments
  return Invoke-Captured -FilePath $commandLine.FilePath -RawArguments $commandLine.Arguments -Environment $Environment -TimeoutSec $TimeoutSec
}

function Invoke-CurlText {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Proxy = "",
    [int]$TimeoutSec = 10
  )

  $curl = $env:OPENCODE_WARP_CURL
  if ($curl -and -not (Test-Path -LiteralPath $curl -PathType Leaf)) { $curl = $null }
  if (-not $curl) {
    $curl = Get-CommandPath "curl.exe"
    if (-not $curl) { $curl = Get-CommandPath "curl" }
  }

  if ($curl) {
    $arguments = @("-sS", "--max-time", [string]$TimeoutSec)
    if ($Proxy) { $arguments += @("-x", $Proxy) }
    $arguments += $Url
    $result = Invoke-ScriptCaptured -ScriptPath $curl -Arguments $arguments
    return [pscustomobject]@{
      Ok       = ($result.ExitCode -eq 0)
      Text     = $result.Output.Trim()
      ExitCode = $result.ExitCode
    }
  }

  try {
    $options = @{
      Uri             = $Url
      TimeoutSec      = $TimeoutSec
      UseBasicParsing = $true
    }
    if ($Proxy) { $options.Proxy = $Proxy }
    $response = Invoke-WebRequest @options
    $text = [string]$response.Content
    return [pscustomobject]@{ Ok = $true; Text = $text.Trim(); ExitCode = 0 }
  } catch {
    return [pscustomobject]@{ Ok = $false; Text = $_.Exception.Message; ExitCode = 1 }
  }
}

function Test-ProxyReachable {
  param(
    [Parameter(Mandatory = $true)][string]$Proxy,
    [int]$TimeoutSec = 5
  )
  $result = Invoke-CurlText -Url "https://api.ipify.org" -Proxy $Proxy -TimeoutSec $TimeoutSec
  return $result.Ok
}

function Get-EgressTrace {
  param(
    [Parameter(Mandatory = $true)][string]$Proxy,
    [int]$TimeoutSec = 10
  )
  $result = Invoke-CurlText -Url "https://www.cloudflare.com/cdn-cgi/trace" -Proxy $Proxy -TimeoutSec $TimeoutSec
  if (-not $result.Ok) { return @() }
  return @($result.Text -split "`r?`n" | Where-Object { $_ -match "^(ip|loc|warp)=" })
}

function Get-EpochSeconds {
  $epoch = [DateTime]::SpecifyKind([DateTime]"1970-01-01", [DateTimeKind]::Utc)
  return [long](([DateTime]::UtcNow - $epoch).TotalSeconds)
}

function Read-StateEpoch {
  param([string]$Name)
  $paths = Get-OpenCodeWarpPaths
  $path = Join-Path $paths.State $Name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $text = Read-TextFile $path
  if ($text -match "^\s*(\d+)") { return [long]$Matches[1] }
  return $null
}

function Write-StateEpoch {
  param([string]$Name, [long]$Epoch)
  $paths = Get-OpenCodeWarpPaths
  if (-not (Test-Path -LiteralPath $paths.State -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $paths.State | Out-Null
  }
  $path = Join-Path $paths.State $Name
  [IO.File]::WriteAllText($path, [string]$Epoch)
}

function Remove-StateFile {
  param([string]$Name)
  $paths = Get-OpenCodeWarpPaths
  $path = Join-Path $paths.State $Name
  Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

function Get-LastRateLimitEpoch {
  $log = Find-OpenCodeLog
  if (-not $log) { return $null }

  try {
    $lines = Get-Content -LiteralPath $log -Tail 4000 -ErrorAction Stop
  } catch {
    return $null
  }

  $pattern = "^timestamp=(\S+)\s+level=ERROR\s+.*(Free usage limit reached|Free messages|Rate limit exceeded|QuotaExceeded|Too Many Requests|HTTP 429|status[=: ]*429)"
  $found = $null
  foreach ($line in $lines) {
    if ($line -match $pattern) { $found = $line }
  }
  if (-not $found) { return $null }

  $match = [regex]::Match($found, "^timestamp=(\S+)")
  if (-not $match.Success) { return [long]2147483647 }
  $timestamp = $match.Groups[1].Value
  try {
    $dto = [DateTimeOffset]::Parse($timestamp, [Globalization.CultureInfo]::InvariantCulture)
    $epoch = [DateTime]::SpecifyKind([DateTime]"1970-01-01", [DateTimeKind]::Utc)
    return [long](($dto.UtcDateTime - $epoch).TotalSeconds)
  } catch {
    # An unparseable timestamp must be conservative: probe rather than skip.
    return [long]2147483647
  }
}

function Find-Probe {
  if ($env:OPENCODE_WARP_PROBE -and (Test-Path -LiteralPath $env:OPENCODE_WARP_PROBE -PathType Leaf)) {
    return $env:OPENCODE_WARP_PROBE
  }
  $paths = Get-OpenCodeWarpPaths
  $candidates = @(
    (Join-Path $PSScriptRoot "probe.ps1"),
    (Join-Path $paths.Bin "probe.ps1")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  return $null
}

function Find-Rotate {
  if ($env:OPENCODE_WARP_ROTATE -and (Test-Path -LiteralPath $env:OPENCODE_WARP_ROTATE -PathType Leaf)) {
    return $env:OPENCODE_WARP_ROTATE
  }
  $paths = Get-OpenCodeWarpPaths
  $candidates = @(
    (Join-Path $PSScriptRoot "warp-rotate.ps1"),
    (Join-Path $paths.Bin "warp-rotate.ps1")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  return $null
}

function Get-OpenCodeWarpProfileBlock {
  return @'
# >>> opencode-warp shortcut >>>
# `opencode --stand [args...]` routes opencode through the local WARP proxy
# (127.0.0.1:40000). run/TUI sessions get --standalone; `serve` and `--server`
# do not. Without --stand it behaves like normal opencode.
function global:opencode {
    if ($args.Count -gt 0 -and $args[0] -eq '--stand') {
        $rest = @()
        if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }
        $warpHome = $env:OPENCODE_WARP_HOME
        if (-not $warpHome) { $warpHome = Join-Path $env:LOCALAPPDATA 'opencode-warp' }
        & (Join-Path $warpHome 'bin\opencode-warp.cmd') @rest
        $code = $LASTEXITCODE
        if ($null -ne $code) { $global:LASTEXITCODE = $code }
        return
    }

    $app = Get-Command opencode -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notlike '*opencode-warp*' } |
        Select-Object -First 1
    if ($app) {
        & $app.Source @args
        $code = $LASTEXITCODE
        if ($null -ne $code) { $global:LASTEXITCODE = $code }
    } else {
        Write-Error 'opencode not found on PATH'
    }
}
# <<< opencode-warp shortcut <<<
'@
}

function Get-PowerShellProfilePaths {
  $paths = @()
  if ($PROFILE.CurrentUserAllHosts) { $paths += $PROFILE.CurrentUserAllHosts }

  $documents = [Environment]::GetFolderPath("MyDocuments")
  if (-not $documents) { $documents = Join-Path (Get-UserHome) "Documents" }
  if ($documents) {
    if (Get-CommandPath "pwsh.exe") {
      $paths += (Join-Path $documents "PowerShell\profile.ps1")
    }
    if (Get-CommandPath "powershell.exe") {
      $paths += (Join-Path $documents "WindowsPowerShell\profile.ps1")
    }
  }

  $unique = @()
  foreach ($path in $paths) {
    if ($path -and ($unique -notcontains $path)) { $unique += $path }
  }
  return $unique
}

function Install-ProfileBlock {
  param([string]$Path)
  $directory = Split-Path -Parent $Path
  if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
  }

  $existing = ""
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $existing = [IO.File]::ReadAllText($Path)
  }

  $block = Get-OpenCodeWarpProfileBlock
  $pattern = "(?ms)^# >>> opencode-warp shortcut >>>.*?^# <<< opencode-warp shortcut <<<\r?\n?"
  $updated = [regex]::Replace($existing, $pattern, "")
  $updated = $updated.TrimEnd() + "`r`n`r`n" + $block.TrimEnd() + "`r`n"

  if ($updated -eq $existing) { return $false }

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $backup = $Path + ".bak.opencode-warp." + (Get-Date -Format "yyyyMMddHHmmss")
    Copy-Item -LiteralPath $Path -Destination $backup -Force
  }

  $encoding = New-Object System.Text.UTF8Encoding($true)
  [IO.File]::WriteAllText($Path, $updated, $encoding)
  return $true
}

function Remove-ProfileBlock {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

  $existing = [IO.File]::ReadAllText($Path)
  $pattern = "(?ms)^# >>> opencode-warp shortcut >>>.*?^# <<< opencode-warp shortcut <<<\r?\n?"
  $updated = [regex]::Replace($existing, $pattern, "").TrimEnd()
  if ($updated -eq $existing) { return $false }

  $backup = $Path + ".bak.opencode-warp." + (Get-Date -Format "yyyyMMddHHmmss")
  Copy-Item -LiteralPath $Path -Destination $backup -Force

  $encoding = New-Object System.Text.UTF8Encoding($true)
  [IO.File]::WriteAllText($Path, $updated, $encoding)
  return $true
}

function Add-UserPath {
  param([string]$Directory)
  if (-not (Test-IsWindows)) {
    if (($env:Path -split ":") -notcontains $Directory) {
      $env:Path = $Directory + ":" + $env:Path
    }
    return $false
  }

  $current = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $current) { $current = "" }
  $parts = @($current -split ";" | Where-Object { $_ })
  if ($parts -contains $Directory) { return $false }

  $updated = (@($parts) + $Directory) -join ";"
  [Environment]::SetEnvironmentVariable("Path", $updated, "User")
  return $true
}

function Remove-UserPath {
  param([string]$Directory)
  if (-not (Test-IsWindows)) {
    $parts = @($env:Path -split ":" | Where-Object { $_ -and $_ -ne $Directory })
    $env:Path = $parts -join ":"
    return $false
  }

  $current = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $current) { return $false }
  $parts = @($current -split ";" | Where-Object { $_ })
  if ($parts -notcontains $Directory) { return $false }

  $updated = @($parts | Where-Object { $_ -ne $Directory }) -join ";"
  [Environment]::SetEnvironmentVariable("Path", $updated, "User")
  return $true
}

function Invoke-CheckedCommand {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [switch]$AllowFailure
  )
  $result = Invoke-Captured -FilePath $FilePath -Arguments $Arguments
  if (-not $AllowFailure -and $result.ExitCode -ne 0) {
    throw ("command failed (exit {0}): {1} {2}`n{3}" -f $result.ExitCode, $FilePath, ($Arguments -join " "), $result.Output)
  }
  return $result
}
