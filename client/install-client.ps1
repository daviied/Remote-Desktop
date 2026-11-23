#Requires -RunAsAdministrator
<#
  Windows client (laptop / desktop) setup.
  WireGuard (your own tunnel, default). HostName = the host's fixed LAN IP:
    .\install-client.ps1 -HostName 192.168.1.20 -MoonlightInstaller C:\Downloads\MoonlightSetup.exe -UsbToken <token>
  Tailscale / headscale:
    .\install-client.ps1 -Network tailscale -LoginServer https://rd.example.com -AuthKey <key> -MoonlightInstaller ... -UsbToken <token>
#>
param(
  [ValidateSet("wireguard", "tailscale")] [string]$Network = "wireguard",
  [string]$HostName = "",            # wireguard: host LAN IP (required). tailscale: default rd-host
  [string]$LoginServer = "",         # tailscale only
  [string]$AuthKey = "",             # tailscale only
  [string]$MoonlightInstaller = "",  # RD Moonlight build (your moonlight-qt fork's Actions). Empty = stock Moonlight
  [string]$UsbToken = "",            # enables USB passthrough
  [switch]$SkipMoonlight,            # the setup.exe installs RD Moonlight itself
  [string]$LogFile = ""              # setup.exe: write a transcript here
)
$ErrorActionPreference = "Stop"
if ($LogFile) { Start-Transcript -Path $LogFile -Force | Out-Null }
function Install-Winget([string]$id, [string]$scope = "") {
  $a = @("install", "-e", "--id", $id, "--accept-source-agreements", "--accept-package-agreements", "--silent")
  if ($scope) { $a += @("--scope", $scope) }
  winget @a
}

if ($Network -eq "tailscale") {
  if (-not ($LoginServer -and $AuthKey)) { throw "-Network tailscale needs -LoginServer and -AuthKey" }
  if (-not $HostName) { $HostName = "rd-host" }
  Install-Winget Tailscale.Tailscale
  & "C:\Program Files\Tailscale\tailscale.exe" up --login-server $LoginServer --authkey $AuthKey --reset
  if ($LASTEXITCODE -ne 0) { throw "tailscale up failed" }
  $hostNets = @("100.64.0.0/10")
  $fw = @{ RemoteAddress = $hostNets; InterfaceAlias = "Tailscale" }
} else {
  $ip = $null
  if (-not [System.Net.IPAddress]::TryParse($HostName, [ref]$ip)) { throw "-Network wireguard needs -HostName <host LAN IP>" }
  Write-Host "WireGuard mode: connect your tunnel before you start Moonlight."
  $hostNets = @("$HostName/32")
  $fw = @{ RemoteAddress = $HostName }   # only the host may connect to this client's USB/IP port
}

if ($SkipMoonlight) { Install-Winget Microsoft.VCRedist.2015+.x64 }   # runtime for the bundled app
elseif ($MoonlightInstaller) { Start-Process $MoonlightInstaller -ArgumentList "/quiet" -Wait }
else {
  Write-Warning "No -MoonlightInstaller: installing stock Moonlight (no profiles, client cursor, battery, outlet wake)."
  Install-Winget MoonlightGameStreamingProject.Moonlight
}

if ($UsbToken) {
  Write-Host "== USB passthrough (usbipd-win + rd-usb agent)"
  Install-Winget dorssel.usbipd-win
  Install-Winget Python.Python.3.12 machine
  $py = "C:\Program Files\Python312\pythonw.exe"
  if (-not (Test-Path $py)) { throw "Python not found at $py" }
  # Agent runs elevated: keep its code + token where only admins can write / read
  $dir = Join-Path $env:ProgramData "RD"
  New-Item -ItemType Directory -Force $dir | Out-Null
  icacls $dir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null
  Copy-Item (Join-Path $PSScriptRoot "rd-usb.py") $dir -Force
  @{ host = $HostName; port = 47900; token = $UsbToken; subnets = $hostNets; allow = @(); deny = @() } |
    ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $dir "usb.json")
  # usbipd listens on 3240: only the host may connect
  Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -like "usbipd*" | Set-NetFirewallRule @fw

  $act = New-ScheduledTaskAction -Execute $py -Argument "-I `"$dir\rd-usb.py`" run"
  $prin = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
  Register-ScheduledTask -TaskName "RD USB Share" -Action $act -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $prin `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0) -Force | Out-Null
  Start-ScheduledTask -TaskName "RD USB Share"
  Write-Host "Check what is shared (admin): python `"$dir\rd-usb.py`" list"
}

Write-Host "Done. Moonlight -> Add PC: $HostName (and ${HostName}:48089 / ${HostName}:48189 for displays 2 and 3)."
