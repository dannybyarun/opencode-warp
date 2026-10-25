#Requires -Version 5.1
#
# setup.ps1 - install the Windows opencode-warp tools.
#
# Installs per-user files under %LOCALAPPDATA%\opencode-warp, adds the bin
# directory to the user PATH, installs the live 429 plugin, and adds an
# `opencode --stand` function to the PowerShell profile.
#
# WARP itself is installed with winget, falling back to Cloudflare's MSI.
# That step needs an elevated PowerShell. If WARP is already installed, the
# rest of the setup can run as a normal user.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup.ps1 -SkipWarpInstall
#
# Options:
#   -SkipWarpInstall     require an existing WARP install
#   -SkipOpenCodeInstall require an existing opencode binary
#   -NoProfile           do not edit PowerShell profiles
#   -NoPath              do not edit the user PATH
#   -Force               overwrite installed files even when unchanged
#   -ValidateOnly        check this repository's Windows files and exit

param(
  [switch]$SkipWarpInstall,
  [switch]$SkipOpenCodeInstall,
  [switch]$NoProfile,
  [switch]$NoPath,
  [switch]$Force,
  [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "common.ps1")

function Say([string]$Message) { Write-Host ""; Write-Host "==> $Message" }
function Ok([string]$Message) { Write-Host "    ok: $Message" }
function Warn([string]$Message) { Write-Host "    !  $Message" }
function Fail([string]$Message) { Write-Host ""; Write-Host "ERROR: $Message" -ForegroundColor Red; exit 1 }

$requiredFiles = @(
  "common.ps1",
  "probe.ps1",
  "warp-rotate.ps1",
  "opencode-warp.ps1",
  "uninstall.ps1",
  "opencode-warp.cmd",
  "opencode-stand.cmd",
  "probe.cmd",
  "warp-rotate.cmd"
)

if ($ValidateOnly) {
  $failures = 0
  foreach ($file in $requiredFiles) {
    $path = Join-Path $PSScriptRoot $file
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      Write-Output "ok   - $file"
    } else {
      Write-Output "FAIL - $file (missing)"
      $failures++
    }
  }

  $plugin = Join-Path (Split-Path -Parent $PSScriptRoot) "opencode-warp-rotate.ts"
  if (Test-Path -LiteralPath $plugin -PathType Leaf) {
    Write-Output "ok   - opencode-warp-rotate.ts"
  } else {
    Write-Output "FAIL - opencode-warp-rotate.ts (missing)"
    $failures++
  }

  foreach ($file in $requiredFiles | Where-Object { $_ -like "*.ps1" }) {
    $path = Join-Path $PSScriptRoot $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -eq 0) {
      Write-Output "ok   - $file parses"
    } else {
      foreach ($error in $errors) {
        Write-Output ("FAIL - {0}:{1}: {2}" -f $file, $error.Extent.StartLineNumber, $error.Message)
      }
      $failures++
    }
  }

  if ($failures -gt 0) { exit 1 }
  Write-Output "validation ok"
  exit 0
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
  Fail "PowerShell 5.1 or newer is required (found $($PSVersionTable.PSVersion))"
}

if (-not (Test-IsWindows)) {
  Fail "this installer is for Windows. On Linux use ./setup.sh instead."
}

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
  # Older .NET may not offer Tls12 by name; Invoke-WebRequest still works.
}

$port = 40000
if ($env:WARP_PROXY_PORT) {
  $parsedPort = 0
  if ([int]::TryParse($env:WARP_PROXY_PORT, [ref]$parsedPort) -and $parsedPort -gt 0 -and $parsedPort -le 65535) {
    $port = $parsedPort
  }
}
$proxy = "http://127.0.0.1:$port"

$paths = Get-OpenCodeWarpPaths
$homeDir = Get-UserHome

function Install-Files {
  Say "Installing opencode-warp under $($paths.Home)"
  if (-not (Test-Path -LiteralPath $paths.Bin -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $paths.Bin | Out-Null
  }

  foreach ($file in $requiredFiles) {
    $source = Join-Path $PSScriptRoot $file
    $target = Join-Path $paths.Bin $file
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      Fail "missing repository file: $source"
    }
    if (-not $Force -and (Test-Path -LiteralPath $target -PathType Leaf)) {
      $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
      $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
      if ($sourceHash -eq $targetHash) {
        Ok "$file unchanged"
        continue
      }
    }
    Copy-Item -LiteralPath $source -Destination $target -Force
    Ok "$file"
  }
}

function Install-Plugin {
  $configDir = Get-OpenCodeConfigDir
  $pluginDir = Join-Path $configDir "plugins"
  $source = Join-Path (Split-Path -Parent $PSScriptRoot) "opencode-warp-rotate.ts"
  $target = Join-Path $pluginDir "opencode-warp-rotate.ts"

  Say "Installing the live 429-recovery plugin"
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    Fail "missing plugin source: $source"
  }
  if (-not (Test-Path -LiteralPath $pluginDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
  }
  Copy-Item -LiteralPath $source -Destination $target -Force
  Ok "installed in $pluginDir"
}

function Install-Profiles {
  if ($NoProfile) {
    Say "Skipping PowerShell profile changes (-NoProfile)"
    return
  }

  Say "Adding the opencode --stand function to PowerShell profiles"
  $profiles = @(Get-PowerShellProfilePaths)
  if ($profiles.Count -eq 0) {
    Warn "could not determine a PowerShell profile path; use opencode-warp directly"
    return
  }

  foreach ($profilePath in $profiles) {
    try {
      $changed = Install-ProfileBlock -Path $profilePath
      if ($changed) {
        Ok "$profilePath (timestamped backup made)"
      } else {
        Ok "$profilePath already current"
      }
    } catch {
      Warn "could not update $profilePath : $($_.Exception.Message)"
    }
  }
}

function Install-UserPaths {
  if ($NoPath) {
    Say "Skipping PATH changes (-NoPath)"
    return
  }

  Say "Adding directories to the user PATH"
  if (Add-UserPath $paths.Bin) {
    Ok $paths.Bin
  } else {
    Ok "$($paths.Bin) already present"
  }
  if (($env:Path -split ";") -notcontains $paths.Bin) {
    $env:Path = $paths.Bin + ";" + $env:Path
  }
}

function Get-WarpService {
  foreach ($name in @("CloudflareWARP", "Cloudflare WARP", "warp-svc")) {
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($service) { return $service }
  }
  return $null
}

function Start-WarpService {
  $service = Get-WarpService
  if (-not $service) {
    Start-Sleep -Seconds 5
    $service = Get-WarpService
  }
  if (-not $service) {
    Warn "WARP service not found; warp-cli may start it on demand"
    return $false
  }

  if ($service.Status -ne "Running") {
    Say "Starting the WARP service ($($service.Name))"
    try {
      Start-Service -Name $service.Name
    } catch {
      Fail "could not start the WARP service: $($_.Exception.Message). Re-run setup from an elevated PowerShell."
    }
    for ($i = 0; $i -lt 30; $i++) {
      $service = Get-WarpService
      if ($service -and $service.Status -eq "Running") { break }
      Start-Sleep -Seconds 1
    }
  }

  $service = Get-WarpService
  if ($service -and $service.Status -eq "Running") {
    Ok "WARP service is running"
    return $true
  }
  Warn "WARP service did not reach Running"
  return $false
}

function Get-Download {
  param([string]$Url, [string]$OutFile)
  Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
  if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
    throw "download produced no file"
  }
  if ((Get-Item -LiteralPath $OutFile).Length -lt 1024) {
    throw "download is suspiciously small"
  }
}

function Install-Warp {
  if ($SkipWarpInstall) {
    $warpCli = Find-WarpCli
    if (-not $warpCli) {
      Fail "WARP is not installed and -SkipWarpInstall was given.
  Install WARP, put it in local proxy mode on 127.0.0.1:$port, then re-run setup.
  Download: https://1.1.1.1/"
    }
    Ok "using existing WARP at $warpCli"
    return $warpCli
  }

  $warpCli = Find-WarpCli
  if ($warpCli) {
    Ok "WARP already installed: $warpCli"
    return $warpCli
  }

  if (-not (Test-IsAdministrator)) {
    Fail "WARP is not installed and installing it needs Administrator rights.
  Open an elevated PowerShell (right-click > Run as administrator) and run:

    powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"

  Or install WARP yourself, then re-run this script with -SkipWarpInstall."
  }

  $winget = Get-CommandPath "winget.exe"
  if ($winget) {
    Say "Installing Cloudflare WARP with winget"
    $result = Invoke-Captured -FilePath $winget -Arguments @(
      "install", "--id", "Cloudflare.Warp", "-e", "--silent",
      "--accept-package-agreements", "--accept-source-agreements"
    )
    if ($result.ExitCode -eq 0) {
      Ok "winget install succeeded"
    } else {
      Warn "winget install failed (exit $($result.ExitCode)); trying the MSI"
      @($result.Output -split "`r?`n" | Select-Object -Last 6) | ForEach-Object { Write-Host "      $_" }
    }
    Start-Sleep -Seconds 3
    $warpCli = Find-WarpCli
    if ($warpCli) { return $warpCli }
  }

  $installer = Join-Path ([IO.Path]::GetTempPath()) ("cloudflare-warp-" + [Guid]::NewGuid().ToString("N") + ".msi")
  $urls = @(
    "https://downloads.cloudflareclient.com/v1/download/windows/ga",
    "https://1111-releases.cloudflareclient.com/windows/Cloudflare_WARP_Release-x64.msi"
  )

  $downloaded = $false
  foreach ($url in $urls) {
    try {
      Say "Downloading Cloudflare WARP from $url"
      Get-Download -Url $url -OutFile $installer
      $downloaded = $true
      break
    } catch {
      Warn "download failed: $($_.Exception.Message)"
    }
  }
  if (-not $downloaded) {
    Fail "could not download the Cloudflare WARP installer.
  Install it manually from https://1.1.1.1/ and re-run with -SkipWarpInstall."
  }

  Say "Installing Cloudflare WARP (MSI)"
  $msi = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$installer`" /qn /norestart" -Wait -PassThru
  Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
  if ($msi.ExitCode -ne 0 -and $msi.ExitCode -ne 3010) {
    Fail "msiexec failed with exit code $($msi.ExitCode)"
  }
  Ok "MSI install finished"

  Start-Sleep -Seconds 5
  $warpCli = Find-WarpCli
  if (-not $warpCli) {
    Fail "WARP installed but warp-cli.exe was not found.
  Expected: C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
  }
  return $warpCli
}

function Initialize-Warp {
  $warpCli = Install-Warp
  $null = Start-WarpService

  Say "Registering the WARP device (anonymous, no email/account)"
  $show = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "registration", "show")
  $missingRegistration = ($show.Output -imatch "Registration Missing|no registration|not registered")
  if ($show.ExitCode -eq 0 -and -not $missingRegistration) {
    Ok "already registered - leaving the existing registration intact"
  } else {
    $registered = $false
    for ($i = 1; $i -le 5; $i++) {
      $new = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "registration", "new")
      if ($new.ExitCode -eq 0) {
        $registered = $true
        break
      }
      if ($i -lt 5) { Start-Sleep -Seconds 2 }
    }
    if (-not $registered) {
      Fail "could not create a WARP registration. Run this script from an elevated PowerShell and check 'warp-cli status'."
    }
    Ok "registered"
  }

  Say "Setting WARP to proxy mode on 127.0.0.1:$port (no route changes)"
  $mode = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "mode", "proxy")
  if ($mode.ExitCode -ne 0) {
    $mode = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "set-mode", "proxy")
  }
  if ($mode.ExitCode -ne 0) {
    Fail "could not set WARP proxy mode.
  Open the Cloudflare WARP app > Settings > Advanced > Configure Proxy,
  enable the local proxy on port $port, then re-run setup."
  }

  $portSet = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "proxy", "port", [string]$port)
  if ($portSet.ExitCode -ne 0) {
    $portSet = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "set-proxy-port", [string]$port)
  }
  if ($portSet.ExitCode -ne 0) {
    Warn "could not set the WARP proxy port; relying on the current setting"
  } else {
    Ok "proxy port set to $port"
  }

  $null = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "connect")

  $connected = $false
  for ($i = 0; $i -lt 30; $i++) {
    $status = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "status")
    if ($status.Output -match "Connected") {
      $connected = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $connected) {
    Fail "WARP did not connect after waiting. Check 'warp-cli status' and the WARP app."
  }
  Ok "WARP connected"

  $settings = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "settings")
  if ($settings.Output -match "WarpProxy" -or $settings.Output -imatch "mode:\s*proxy") {
    Ok "proxy mode confirmed"
  } elseif ($settings.Output -imatch "mode:") {
    $null = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "disconnect")
    Fail "WARP is not in proxy mode after connecting; refusing to continue because full-tunnel mode changes your routing."
  } else {
    Warn "could not read the WARP mode; the proxy check below is the real test"
  }

  $reachable = $false
  for ($i = 0; $i -lt 30; $i++) {
    if (Test-ProxyReachable -Proxy $proxy -TimeoutSec 3) {
      $reachable = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $reachable) {
    Fail "the WARP proxy is not reachable on $proxy.
  Open the WARP app > Settings > Advanced > Configure Proxy and enable port $port."
  }
  Ok "proxy reachable on $proxy"
}

function Get-OpenCodeDownloadUrl {
  $architecture = $env:PROCESSOR_ARCHITECTURE
  if ($architecture -eq "ARM64") {
    return "https://opencode.ai/update/api/latest/cli/opencode/opencode-windows-arm64.zip"
  }
  return "https://opencode.ai/update/api/latest/cli/opencode/opencode-windows-x64.zip"
}

function Install-OpenCode {
  $opencode = Find-OpenCode
  if ($opencode) {
    Ok "opencode already installed: $opencode"
    return $opencode
  }

  if ($SkipOpenCodeInstall) {
    Fail "opencode is not installed and -SkipOpenCodeInstall was given.
  Install it, then re-run setup. Download: https://opencode.ai/download"
  }

  Say "opencode not found - installing the standalone Windows CLI"

  $npm = Get-CommandPath "npm.cmd"
  if (-not $npm) { $npm = Get-CommandPath "npm" }
  if ($npm) {
    Write-Host "    trying: npm install -g @opencode/cli@latest"
    $npmResult = Invoke-ScriptCaptured -ScriptPath $npm -Arguments @("install", "-g", "@opencode/cli@latest") -TimeoutSec 900
    if ($npmResult.ExitCode -eq 0) {
      Ok "npm install succeeded"
    } else {
      Warn "npm install failed (exit $($npmResult.ExitCode)); using the standalone zip"
    }
  }

  $opencode = Find-OpenCode
  if ($opencode) { return $opencode }

  $zip = Join-Path ([IO.Path]::GetTempPath()) ("opencode-" + [Guid]::NewGuid().ToString("N") + ".zip")
  $extract = Join-Path ([IO.Path]::GetTempPath()) ("opencode-extract-" + [Guid]::NewGuid().ToString("N"))
  $url = Get-OpenCodeDownloadUrl

  Say "Downloading $url"
  try {
    Get-Download -Url $url -OutFile $zip
  } catch {
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Fail "could not download opencode: $($_.Exception.Message)
  Install it manually from https://opencode.ai/download and re-run setup."
  }

  $bytes = [IO.File]::ReadAllBytes($zip)
  if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x50 -or $bytes[1] -ne 0x4B) {
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Fail "the opencode download was not a zip archive; refusing to extract it."
  }

  New-Item -ItemType Directory -Force -Path $extract | Out-Null
  try {
    Expand-Archive -Path $zip -DestinationPath $extract -Force
  } catch {
    Remove-Item -LiteralPath $zip, $extract -Recurse -Force -ErrorAction SilentlyContinue
    Fail "could not extract the opencode zip: $($_.Exception.Message)"
  }
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

  $binary = Get-ChildItem -Path $extract -Filter "opencode.exe" -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if (-not $binary) {
    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    Fail "the opencode zip did not contain opencode.exe"
  }

  $targetDir = Join-Path $homeDir ".opencode\bin"
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  $target = Join-Path $targetDir "opencode.exe"
  Copy-Item -LiteralPath $binary.FullName -Destination $target -Force
  Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue

  if (-not $NoPath) {
    if (Add-UserPath $targetDir) { Ok "added $targetDir to the user PATH" }
    if (($env:Path -split ";") -notcontains $targetDir) {
      $env:Path = $targetDir + ";" + $env:Path
    }
  }

  $opencode = Find-OpenCode
  if (-not $opencode) {
    Fail "opencode was installed to $target but was not found afterwards."
  }
  Ok "installed at $opencode"
  return $opencode
}

# ------------------------------------------------------------------ install
Say "Checking environment"
if (Test-IsAdministrator) {
  Ok "running elevated"
} else {
  Warn "not elevated; WARP installation and service start may need an elevated shell"
}
Ok "PowerShell $($PSVersionTable.PSVersion)"
Ok "architecture $($env:PROCESSOR_ARCHITECTURE)"

Install-Files
Install-Plugin
Install-UserPaths
Install-Profiles

Say "Checking Cloudflare WARP"
Initialize-Warp

Say "Checking opencode"
$opencode = Install-OpenCode
$version = Get-OpenCodeVersion $opencode
Ok "version: $version"

Say "Verifying the wrapper's required flags still exist"
if (-not (Test-OpenCodeStandalone $opencode)) {
  Fail "this opencode version does not support 'run --standalone'.
  The wrapper relies on it, and without it proxy env vars would be ignored
  silently (the background service makes the actual inference calls).
  opencode version: $version"
}
Ok "'run --standalone' available"

# ------------------------------------------------------------------- verify
Say "Verifying the WARP proxy"
$normalIp = ""
$warpIp = ""
try {
  $direct = Invoke-CurlText -Url "https://api.ipify.org" -TimeoutSec 15
  if ($direct.Ok) { $normalIp = $direct.Text }
  $through = Invoke-CurlText -Url "https://api.ipify.org" -Proxy $proxy -TimeoutSec 15
  if ($through.Ok) { $warpIp = $through.Text }
} catch {
  # The explicit check below prints the actionable error.
}
if (-not $warpIp) {
  Fail "the WARP proxy is not reachable on $proxy. Check 'warp-cli status' and the WARP app."
}
Ok "proxy reachable"

Write-Host ""
Say "Done."
Write-Host @"
  Normal egress   : $(if ($normalIp) { $normalIp } else { "?" })
  Through WARP    : $warpIp

  Start a new PowerShell window (so the profile and PATH are loaded), then:

    opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"
    opencode-warp run -m <model> "hello"      # same thing, any shell
    opencode --stand                          # TUI through WARP

  In cmd.exe, use:

    opencode-stand run -m <model> "hello"
    opencode-warp run -m <model> "hello"

  If opencode's log shows a recent rate-limit error, --stand first checks the
  WARP ingress and rotates the anonymous registration when it is throttled:

    `$env:WARP_ROTATE_ATTEMPTS = 3; opencode --stand
    `$env:OPENCODE_WARP_AUTO_ROTATE = 0; opencode ...
    `$env:OPENCODE_WARP_FORCE_PROBE = 1; opencode ...

  Manual check / recovery, useful in any shell:

    & "$($paths.Bin)\probe.ps1"
    & "$($paths.Bin)\warp-rotate.ps1"

  A live 429 plugin was installed for --stand sessions:

    $(Join-Path (Get-OpenCodeConfigDir) "plugins\opencode-warp-rotate.ts")

  NOTE: the 'run' subcommand is still required - --stand only injects
  --standalone, it does not invent the subcommand.
"@
