; RD Host for Windows: wizard around host\install-host.ps1.
; Bundles RD Sunshine (.msi from the Sunshine fork) and rd-hostd.exe.
; Build: iscc /DAppVersion=1.0.0 /DSunshineMsi=<RD Sunshine .msi> /DHostdExe=<rd-hostd.exe> rd-host.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SunshineMsi
  #define SunshineMsi "..\..\build\Sunshine.msi"
#endif
#ifndef HostdExe
  #define HostdExe "..\..\build\rd-hostd.exe"
#endif

[Setup]
AppId={{3F0A9D27-58B4-4E7C-A1D6-7C2E9B4F1D30}
AppName=RD Host
AppVersion={#AppVersion}
AppPublisher=daviied
DefaultDirName={autopf}\RD Host
DisableProgramGroupPage=yes
DisableDirPage=yes
OutputDir=..\..\dist
OutputBaseFilename=RD-Host-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
InfoBeforeFile=host-before.txt

[Files]
Source: "{#SunshineMsi}"; DestDir: "{tmp}"; DestName: "Sunshine.msi"; Flags: deleteafterinstall
Source: "{#HostdExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\host\install-host.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\host\rd-usbhost.py"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\host\power-notify.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion

[Run]
Filename: "{sys}\notepad.exe"; Parameters: """{commonappdata}\RD\setup-summary.txt"""; Description: "Show host address, USB token and next steps"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -Command ""Get-ScheduledTask -TaskName 'RD *' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false; Get-NetFirewallRule -DisplayName 'RD *' -ErrorAction SilentlyContinue | Remove-NetFirewallRule"""; Flags: runhidden; RunOnceId: "RemoveRdTasks"

[UninstallDelete]
Type: filesandordirs; Name: "{commonappdata}\RD"

#include "common.iss"

[Code]
var
  SubnetPage: TInputQueryWizardPage;
  PowerPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  CreateNetworkPages(wpInfoBefore);

  SubnetPage := CreateInputQueryPage(TsPage.ID, 'Allowed networks', 'Who may connect to this host?',
    'Your WireGuard tunnel subnet and home LAN, comma separated. Everything else is blocked by the firewall.');
  SubnetPage.Add('Subnets (e.g. 10.8.0.0/24,192.168.1.0/24):', False);

  PowerPage := CreateInputQueryPage(SubnetPage.ID, 'Smart outlet', 'Turn the outlet off after Windows shuts down (optional)',
    'Leave empty if you do not use rd-power.');
  PowerPage.Add('Power server URL (https://...):', False);
  PowerPage.Add('RD_POWER_TOKEN:', True);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := ((PageID = TsPage.ID) and not UseTailscale) or ((PageID = SubnetPage.ID) and UseTailscale);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  U, T: String;
begin
  Result := True;
  if CurPageID = TsPage.ID then
    Result := CheckTailscalePage
  else if (CurPageID = SubnetPage.ID) and not IsSubnetList(Trim(SubnetPage.Values[0])) then begin
    MsgBox('Type subnets like 10.8.0.0/24,192.168.1.0/24', mbError, MB_OK);
    Result := False;
  end else if CurPageID = PowerPage.ID then begin
    U := Trim(PowerPage.Values[0]);
    T := Trim(PowerPage.Values[1]);
    if ((U <> '') or (T <> '')) and not (IsHttpsUrl(U) and IsToken(T) and (Length(T) >= 16)) then begin
      MsgBox('Type an https:// URL and the token (16+ letters / numbers), or leave both empty.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function SetupParams: String;
begin
  if UseTailscale then
    Result := TailscaleParams
  else
    Result := ' -Network wireguard -AllowedSubnets "' + Trim(SubnetPage.Values[0]) + '"';
  if Trim(PowerPage.Values[0]) <> '' then
    Result := Result + ' -PowerUrl "' + Trim(PowerPage.Values[0]) + '" -PowerToken "' + Trim(PowerPage.Values[1]) + '"';
  Result := Result + ' -SunshineInstaller "' + ExpandConstant('{tmp}\Sunshine.msi') + '"' +
    ' -HostdExe "' + ExpandConstant('{app}\rd-hostd.exe') + '"';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    if not FileExists(ExpandConstant('{commonpf64}\USBip\usbip.exe')) then
      MsgBox('usbip-win2 is not installed: USB passthrough stays off.' + #13#10 +
        'To use it later: install usbip-win2, then run this installer again.', mbInformation, MB_OK);
    RunSetupScript(ExpandConstant('{app}\scripts\install-host.ps1'), SetupParams,
      ExpandConstant('{%TEMP}\rd-host-setup.log'));
  end;
end;
