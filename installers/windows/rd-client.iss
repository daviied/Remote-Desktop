; RD Client for Windows: RD Moonlight + network setup + USB passthrough agent.
; Build: iscc /DAppVersion=1.0.0 /DMoonlightDir=<folder with Moonlight.exe> rd-client.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef MoonlightDir
  #define MoonlightDir "..\..\build\moonlight"
#endif

[Setup]
AppId={{8C1E6B52-6E0B-4C1F-9C55-2B1D3E7A9A11}
AppName=RD Client
AppVersion={#AppVersion}
AppPublisher=daviied
DefaultDirName={autopf}\RD Client
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=RD-Client-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
UninstallDisplayIcon={app}\Moonlight\Moonlight.exe
CloseApplications=yes

[Tasks]
Name: desktopicon; Description: "Desktop shortcut"

[Files]
Source: "{#MoonlightDir}\*"; DestDir: "{app}\Moonlight"; Flags: recursesubdirs ignoreversion
Source: "..\..\client\install-client.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\client\rd-usb.py"; DestDir: "{app}\scripts"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\RD Moonlight"; Filename: "{app}\Moonlight\Moonlight.exe"
Name: "{autodesktop}\RD Moonlight"; Filename: "{app}\Moonlight\Moonlight.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Moonlight\Moonlight.exe"; Description: "Start RD Moonlight"; Flags: postinstall nowait skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -Command ""Unregister-ScheduledTask -TaskName 'RD USB Share' -Confirm:$false -ErrorAction SilentlyContinue"""; Flags: runhidden; RunOnceId: "RemoveUsbTask"

[UninstallDelete]
Type: files; Name: "{commonappdata}\RD\usb.json"
Type: files; Name: "{commonappdata}\RD\rd-usb.py"

#include "common.iss"

[Code]
var
  HostPage: TInputQueryWizardPage;
  UsbPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  CreateNetworkPages(wpSelectTasks);

  HostPage := CreateInputQueryPage(TsPage.ID, 'Host', 'Windows host address',
    'The fixed LAN IP of the host PC (the host installer shows it at the end).');
  HostPage.Add('Host LAN IP (e.g. 192.168.1.20):', False);

  UsbPage := CreateInputQueryPage(HostPage.ID, 'USB passthrough', 'Share USB drives and boards with the host (optional)',
    'Paste the USB token from the host setup summary. Leave empty to turn USB passthrough off.' + #13#10 +
    'Keyboards, mice, controllers and network adapters are never shared.');
  UsbPage.Add('USB token:', True);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := ((PageID = TsPage.ID) and not UseTailscale) or ((PageID = HostPage.ID) and UseTailscale);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = TsPage.ID then
    Result := CheckTailscalePage
  else if (CurPageID = HostPage.ID) and not IsIPv4(Trim(HostPage.Values[0])) then begin
    MsgBox('Type the host LAN IP, e.g. 192.168.1.20', mbError, MB_OK);
    Result := False;
  end else if (CurPageID = UsbPage.ID) and (Trim(UsbPage.Values[0]) <> '') and not IsToken(Trim(UsbPage.Values[0])) then begin
    MsgBox('The USB token has letters and numbers only.', mbError, MB_OK);
    Result := False;
  end;
end;

function SetupParams: String;
begin
  if UseTailscale then
    Result := TailscaleParams
  else
    Result := ' -Network wireguard -HostName "' + Trim(HostPage.Values[0]) + '"';
  if Trim(UsbPage.Values[0]) <> '' then
    Result := Result + ' -UsbToken "' + Trim(UsbPage.Values[0]) + '"';
  Result := Result + ' -SkipMoonlight';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    RunSetupScript(ExpandConstant('{app}\scripts\install-client.ps1'), SetupParams,
      ExpandConstant('{%TEMP}\rd-client-setup.log'));
end;
