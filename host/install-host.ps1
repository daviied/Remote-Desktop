#Requires -RunAsAdministrator
<#
  Sets up the Windows host (NVIDIA GPU).
   - Network: your own WireGuard tunnel (default) or Tailscale/headscale (-Network tailscale)
   - Sunshine RD build: NVENC low latency, mandatory encryption, client-drawn cursor, client battery
   - 3 Sunshine instances = 3 virtual displays (base ports 47989 / 48089 / 48189)
     Each connection turns its virtual display on at the client's resolution/refresh; off on disconnect.
   - rd-hostd tray: client battery icons in the taskbar
   - USB passthrough agent (rd-usbhost, needs usbip-win2)
   - Smart-outlet power: tells rd-power when Windows powers off
  Prereq: Virtual Display Driver installed with 3 monitors (README).

  WireGuard (your tunnel ends on the router / a home server; host is on the LAN):
  .\install-host.ps1 -AllowedSubnets 10.8.0.0/24,192.168.1.0/24 `
      -SunshineInstaller C:\Downloads\Sunshine-Windows-AMD64-installer.msi `
      -PowerUrl https://rd.example.com -PowerToken <RD_POWER_TOKEN>
  Tailscale: add -Network tailscale -LoginServer https://rd.example.com -AuthKey <tag:host key>
#>
param(
  [ValidateSet("wireguard", "tailscale")] [string]$Network = "wireguard",
  [string[]]$AllowedSubnets = @(),   # wireguard: tunnel + LAN subnets allowed to connect
  [string]$LoginServer = "",         # tailscale only
  [string]$AuthKey = "",             # tailscale only
  [string]$SunshineInstaller = "",   # RD Sunshine .msi (or .exe) from your Sunshine fork's Actions. Empty = stock Sunshine (no cursor/battery features)
  [string]$HostdExe = "",            # Local rd-hostd.exe. Empty = download from your repo's latest release
  [string]$Repo = "daviied/Remote-Desktop",
  [string]$PowerUrl = "",
  [string]$PowerToken = "",
  [string]$HostName = "rd-host",
  [string]$LogFile = ""              # setup.exe: write a transcript here
)
$ErrorActionPreference = "Stop"
if ($LogFile) { Start-Transcript -Path $LogFile -Force | Out-Null }
$rd = Join-Path $env:ProgramData "RD"
New-Item -ItemType Directory -Force $rd | Out-Null
# Lock the RD folder: SYSTEM tasks run code from here, so normal users must not write to it.
# (SIDs: S-1-5-18 SYSTEM, S-1-5-32-544 Administrators, S-1-5-32-545 Users)
icacls $rd /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" | Out-Null
New-Item -ItemType Directory -Force (Join-Path $rd "clients") | Out-Null
$hostdLog = Join-Path $rd "rd-hostd.log"
if (-not (Test-Path $hostdLog)) { New-Item -ItemType File $hostdLog | Out-Null }
icacls $hostdLog /grant "*S-1-5-32-545:M" | Out-Null   # log file only (Sunshine runs rd-hostd as the user)
if ($Network -eq "tailscale") {
  if (-not ($LoginServer -and $AuthKey)) { throw "-Network tailscale needs -LoginServer and -AuthKey" }
  $allowed = @("100.64.0.0/10")
  $fw = @{ RemoteAddress = $allowed; InterfaceAlias = "Tailscale" }   # adapter AND address range
} else {
  if (-not $AllowedSubnets) { throw "-Network wireguard needs -AllowedSubnets, e.g. 10.8.0.0/24,192.168.1.0/24" }
  $allowed = @($AllowedSubnets | ForEach-Object { $_ -split "," } | Where-Object { $_ })
  $fw = @{ RemoteAddress = $allowed }
}
@{ mode = $Network; subnets = $allowed } | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $rd "network.json")
$python = "C:\Program Files\Python312\pythonw.exe"

function Install-Winget([string]$id, [string]$scope = "") {
  $a = @("install", "-e", "--id", $id, "--accept-source-agreements", "--accept-package-agreements", "--silent")
  if ($scope) { $a += @("--scope", $scope) }
  winget @a
}

Write-Host "== Private network ($Network)"
if ($Network -eq "tailscale") {
  Install-Winget Tailscale.Tailscale
  $ts = "C:\Program Files\Tailscale\tailscale.exe"
  & $ts up --login-server $LoginServer --authkey $AuthKey --hostname $HostName --unattended --reset
  if ($LASTEXITCODE -ne 0) { throw "tailscale up failed" }
  $hostIp = (& $ts ip -4)
} else {
  $hostIp = (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway | Select-Object -First 1).IPv4Address.IPAddress
  Write-Host "Using your WireGuard tunnel. Allowed: $($allowed -join ', '). Give this PC a fixed LAN IP ($hostIp)."
}

Write-Host "== Sunshine"
if ($SunshineInstaller) {
  if ($SunshineInstaller -like "*.msi") {
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$SunshineInstaller`" /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "Sunshine install failed ($($p.ExitCode))" }
  } else {
    Start-Process $SunshineInstaller -ArgumentList "/S" -Wait
  }
} else {
  Write-Warning "No -SunshineInstaller: installing stock Sunshine. Client-drawn cursor and battery icons need the RD build."
  Install-Winget LizardByte.Sunshine
}

Write-Host "== rd-hostd"
$hostd = Join-Path $rd "rd-hostd.exe"
if ($HostdExe) { Copy-Item $HostdExe $hostd -Force }
else { Invoke-WebRequest "https://github.com/$Repo/releases/latest/download/rd-hostd.exe" -OutFile $hostd }
& $hostd display list
$vddCount = 0
if ((& $hostd display list | Select-Object -First 1) -match "^(\d+) virtual") { $vddCount = [int]$Matches[1] }

$sun    = "C:\Program Files\Sunshine"
$cfgDir = Join-Path $sun "config"
$hostdJson = $hostd.Replace('\', '\\')

$common = @"
encoder = nvenc
nvenc_preset = 1
nvenc_twopass = disabled
nvenc_spatial_aq = disabled
nvenc_vbv_increase = 0
nvenc_realtime_hags = enabled
nvenc_latency_over_power = enabled
lan_encryption_mode = 2
wan_encryption_mode = 2
origin_web_ui_allowed = lan
dd_configuration_option = disabled
min_log_level = warning
"@

function Get-Ports([int]$base) {
  # Parentheses needed: in PowerShell the comma binds before + and -
  @{ tcp = @(($base - 5), $base, ($base + 1), ($base + 21)); udp = @(($base + 9), ($base + 10), ($base + 11), ($base + 13), ($base + 21)) }
}

Write-Host "== Sunshine instances (one per virtual display)"
$names = @{ 1 = "RD-Display1"; 2 = "RD-Display2"; 3 = "RD-Display3" }
foreach ($n in 1..3) {
  $base = 47989 + 100 * ($n - 1)
  $prep = "global_prep_cmd = [{`"do`":`"$hostdJson display attach $n`",`"undo`":`"$hostdJson display detach $n`",`"elevated`":false}]"
  if ($n -eq 1) {
    # Display 1: the Sunshine Windows service
    Set-Content -Encoding ascii (Join-Path $cfgDir "sunshine.conf") "sunshine_name = $($names[$n])`nport = $base`n$prep`n$common"
    continue
  }
  $conf = Join-Path $cfgDir "sunshine-$n.conf"
  Set-Content -Encoding ascii $conf @"
sunshine_name = $($names[$n])
port = $base
file_state = $cfgDir\sunshine_state_$n.json
credentials_file = $cfgDir\sunshine_state_$n.json
file_apps = $cfgDir\apps_$n.json
log_path = $cfgDir\sunshine_$n.log
pkey = $cfgDir\credentials_$n\cakey.pem
cert = $cfgDir\credentials_$n\cacert.pem
$prep
$common
"@
  Set-Content -Encoding ascii (Join-Path $cfgDir "apps_$n.json") '{"env":{},"apps":[{"name":"Desktop","image-path":"desktop.png"}]}'

  $act  = New-ScheduledTaskAction -Execute (Join-Path $sun "sunshine.exe") -Argument "`"$conf`"" -WorkingDirectory $sun
  $prin = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
  $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit 0 -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
  Register-ScheduledTask -TaskName "RD Sunshine Display $n" -Action $act -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $prin -Settings $set -Force | Out-Null

  $p = Get-Ports $base
  foreach ($proto in "tcp", "udp") {
    $rule = "RD Sunshine Display $n $proto"
    Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol $proto.ToUpper() `
      -LocalPort ($p[$proto] | ForEach-Object { "$_" }) @fw | Out-Null
  }
}
# Stock Sunshine rules: private network only
Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object DisplayName -like "Sunshine*" | Set-NetFirewallRule @fw

Write-Host "== Battery tray icons + virtual display reset at logon"
$act  = New-ScheduledTaskAction -Execute $hostd -Argument "tray"
$prin = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
Register-ScheduledTask -TaskName "RD Host Tray" -Action $act -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Principal $prin `
  -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit 0) -Force | Out-Null

Write-Host "== USB passthrough agent"
$usbip = "C:\Program Files\USBip\usbip.exe"
if (-not (Test-Path $usbip)) {
  Write-Warning "usbip-win2 not found. Install it from https://github.com/vadimgrn/usbip-win2/releases, then re-run this script."
} else {
  Install-Winget Python.Python.3.12 machine   # Program Files: not user-writable (runs as SYSTEM)
  if (-not (Test-Path $python)) { throw "Python not found at $python" }
  Copy-Item (Join-Path $PSScriptRoot "rd-usbhost.py") $rd -Force
  $tokFile = Join-Path $rd "usb-token.txt"
  if (-not (Test-Path $tokFile)) {
    $bytes = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    Set-Content -Encoding ascii $tokFile ([BitConverter]::ToString($bytes) -replace "-", "").ToLower()
    icacls $tokFile /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
  }
  # -I: isolated mode (ignores PYTHON* env vars, user site-packages and the script folder for imports)
  $act = New-ScheduledTaskAction -Execute $python -Argument "-I `"$rd\rd-usbhost.py`""
  Register-ScheduledTask -TaskName "RD USB Host" -Action $act -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Principal (New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest) `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit 0 -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)) -Force | Out-Null
  Remove-NetFirewallRule -DisplayName "RD USB Host" -ErrorAction SilentlyContinue
  New-NetFirewallRule -DisplayName "RD USB Host" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 47900 @fw | Out-Null
  Start-ScheduledTask -TaskName "RD USB Host"
  Write-Host "USB token for clients (usb.json 'token'): $(Get-Content $tokFile)"
}

Write-Host "== Smart-outlet power"
if ($PowerUrl -and $PowerToken) {
  $pj = Join-Path $rd "power.json"
  @{ url = $PowerUrl; token = $PowerToken } | ConvertTo-Json | Set-Content -Encoding utf8 $pj
  icacls $pj /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
  Copy-Item (Join-Path $PSScriptRoot "power-notify.ps1") $rd -Force

  # Event trigger: System log, USER32 event 1074 (shutdown / restart started)
  $class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
  $trig = $class | New-CimInstance -ClientOnly
  $trig.Enabled = $true
  $trig.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''User32''] and EventID=1074]]</Select></Query></QueryList>'
  $act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$rd\power-notify.ps1`""
  Register-ScheduledTask -TaskName "RD Power Notify" -Action $act -Trigger $trig `
    -Principal (New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest) -Force | Out-Null
} else {
  Write-Host "Skipped (no -PowerUrl / -PowerToken)."
}

Write-Host "== Power: never sleep on AC"
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /setactive SCHEME_MIN

Restart-Service -Name SunshineService -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName "RD Host Tray"
2..3 | ForEach-Object { Start-ScheduledTask -TaskName "RD Sunshine Display $_" }

$tokFile = Join-Path $rd "usb-token.txt"
$vddLine = if ($vddCount -ge 3) { "Virtual displays: $vddCount found" } else { "WARNING: $vddCount virtual display(s) found. Install Virtual Display Driver with 3 monitors (https://github.com/VirtualDrivers/Virtual-Display-Driver). Until then clients stream the current display at its current resolution." }
$usbLine = if (Test-Path $tokFile) { "USB token (client installer / usb.json): $((Get-Content $tokFile).Trim())" } else { "USB passthrough: off (install usbip-win2, then run setup again)" }
$summary = @"
RD host setup done ($Network mode).

Host address for clients: $hostIp
$vddLine
$usbLine

Next steps:
 1. $hostd display attach-all   (turn all virtual displays on once)
 2. https://localhost:47990 / 48090 / 48190 -> set login -> Audio/Video -> Display = virtual display 1 / 2 / 3
 3. $hostd display init
 4. BIOS: 'Restore on AC power loss' = Power On (for the smart outlet)
 5. Pair each client: Moonlight shows a PIN -> enter it in the web UI (47990 / 48090 / 48190)

This file holds the USB token: only administrators can read it.
"@
$sumFile = Join-Path $rd "setup-summary.txt"
Set-Content -Encoding utf8 $sumFile $summary
icacls $sumFile /inheritance:r /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" | Out-Null
Write-Host ""
Write-Host $summary
