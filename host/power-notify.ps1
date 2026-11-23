<#
  Runs at Windows shutdown/restart (scheduled task on System event 1074).
  On a real power-off it tells rd-power to switch the outlet off once this PC is offline.
  Restarts are ignored. Settings: %ProgramData%\RD\power.json  {"url": "https://rd.example.com", "token": "..."}
#>
$ErrorActionPreference = "Stop"
$cfgPath = Join-Path $env:ProgramData "RD\power.json"
if (-not (Test-Path $cfgPath)) { exit 0 }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

# Latest 1074 event: property 4 is the shutdown type ("power off" / "restart"), in English on en-US systems.
$evt = Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = 1074 } -MaxEvents 1
$kind = "$($evt.Properties[4].Value)".ToLowerInvariant()
if ($kind -match "restart|neustart|redémarrage|reinicio|riavvio") { exit 0 }

$body = '{"type":"poweroff"}'
Invoke-RestMethod -Method Post -Uri ($cfg.url.TrimEnd('/') + "/power/shutdown") -Body $body `
  -ContentType "application/json" -Headers @{ Authorization = "Bearer $($cfg.token)" } -TimeoutSec 10 | Out-Null
