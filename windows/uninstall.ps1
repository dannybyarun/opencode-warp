#Requires -Version 5.1
#
# uninstall.ps1 - remove the Windows opencode-warp tools.
#
#   .\windows\uninstall.ps1          remove wrapper, helpers, plugin, profile
#                                    block, PATH entry and state
#   .\windows\uninstall.ps1 -Purge   also remove the WARP package, service and
#                                    anonymous device registration
#
# -Purge needs an elevated PowerShell.

param(
  [switch]$Purge
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Say([string]$Message) { Write-Host ""; Write-Host "==> $Message" }
function Ok([string]$Message) { Write-Host "    ok: $Message" }
function Warn([string]$Message) { Write-Host "    !  $Message" }

if (-not (Test-IsWindows)) {
  Write-Host "ERROR: this uninstaller is for Windows. On Linux use ./uninstall.sh" -ForegroundColor Red
  exit 1
}

if ($Purge -and -not (Test-IsAdministrator)) {
  Write-Host "ERROR: -Purge needs Administrator rights." -ForegroundColor Red
  Write-Host "  Open an elevated PowerShell and run:"
  Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Purge"
  exit 1
}

$paths = Get-OpenCodeWarpPaths

# ---------------------------------------------------------------- profiles
Say "Removing the opencode --stand function from PowerShell profiles"
$profiles = @(Get-PowerShellProfilePaths)
if ($profiles.Count -eq 0) {
  Ok "no profile paths found"
} else {
  foreach ($profilePath in $profiles) {
    try {
      if (Remove-ProfileBlock -Path $profilePath) {
        Ok "$profilePath"
      } else {
        Ok "$profilePath (no block)"
      }
    } catch {
      Warn "could not update $profilePath : $($_.Exception.Message)"
    }
  }
}

# -------------------------------------------------------------------- PATH
Say "Removing the opencode-warp directory from the user PATH"
if (Remove-UserPath $paths.Bin) {
  Ok $paths.Bin
} else {
  Ok "$($paths.Bin) was not present"
}

# ------------------------------------------------------------------ plugin
Say "Removing the live 429-recovery plugin"
$plugin = Join-Path (Join-Path (Get-OpenCodeConfigDir) "plugins") "opencode-warp-rotate.ts"
if (Test-Path -LiteralPath $plugin -PathType Leaf) {
  Remove-Item -LiteralPath $plugin -Force
  Ok "removed $plugin"
} else {
  Ok "not present"
}

# ------------------------------------------------------------------- files
Say "Removing $($paths.Home)"
if (Test-Path -LiteralPath $paths.Home -PathType Container) {
  Remove-Item -LiteralPath $paths.Home -Recurse -Force
  Ok "removed (helpers, state and logs)"
} else {
  Ok "not present"
}

# ------------------------------------------------------------------- purge
if ($Purge) {
  Say "Purging Cloudflare WARP"

  $warpCli = Find-WarpCli
  if ($warpCli) {
    $null = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "disconnect")
    $null = Invoke-ScriptCaptured -ScriptPath $warpCli -Arguments @("--accept-tos", "registration", "delete")
    Ok "disconnected and removed the anonymous registration"
  } else {
    Ok "warp-cli not found"
  }

  foreach ($name in @("CloudflareWARP", "Cloudflare WARP", "warp-svc")) {
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($service) {
      try {
        Stop-Service -Name $service.Name -Force -ErrorAction Stop
        Ok "stopped service $($service.Name)"
      } catch {
        Warn "could not stop service $($service.Name): $($_.Exception.Message)"
      }
    }
  }

  $removed = $false
  $winget = Get-CommandPath "winget.exe"
  if ($winget) {
    $result = Invoke-Captured -FilePath $winget -Arguments @(
      "uninstall", "--id", "Cloudflare.Warp", "-e", "--silent"
    )
    if ($result.ExitCode -eq 0) {
      Ok "winget uninstall succeeded"
      $removed = $true
    } else {
      Warn "winget uninstall failed (exit $($result.ExitCode)); checking the uninstall registry"
    }
  }

  if (-not $removed) {
    $keys = @(
      "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
      "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
      "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $entry = Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -match "Cloudflare (WARP|One|Client)" } |
      Select-Object -First 1
    if ($entry) {
      if ($entry.PSChildName -match '^\{.*\}$') {
        $msi = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $($entry.PSChildName) /qn /norestart" -Wait -PassThru
        if ($msi.ExitCode -eq 0 -or $msi.ExitCode -eq 3010) {
          Ok "MSI uninstall succeeded"
        } else {
          Warn "MSI uninstall returned $($msi.ExitCode)"
        }
      } elseif ($entry.UninstallString) {
        Warn "found an uninstall command but not an MSI product code: $($entry.UninstallString)"
        Warn "run it manually to finish removing WARP"
      }
    } else {
      Warn "could not find the Cloudflare WARP uninstall entry"
    }
  }

  Write-Host ""
  Write-Host "  WARP application data under C:\ProgramData\Cloudflare was left in place."
} else {
  Write-Host ""
  Write-Host "  (WARP itself was left installed and connected."
  Write-Host "   Re-run with -Purge to remove the package and device registration.)"
}

Say "Done. Open a new PowerShell window for the change to take effect."
