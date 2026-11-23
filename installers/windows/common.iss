; Shared wizard code for the RD client and host installers.
; Values typed in the wizard go on a PowerShell command line, so each one is checked
; against a strict character set first (no quotes, spaces or shell characters).

[Code]
var
  NetPage: TInputOptionWizardPage;
  TsPage: TInputQueryWizardPage;

function OnlyChars(const S, Allowed: String): Boolean;
var
  I: Integer;
begin
  Result := Length(S) > 0;
  for I := 1 to Length(S) do
    if Pos(S[I], Allowed) = 0 then begin
      Result := False;
      Exit;
    end;
end;

const
  DIGITS = '0123456789';
  ALNUM = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

function IsIPv4(const S: String): Boolean;
begin
  Result := OnlyChars(S, DIGITS + '.') and (Length(S) >= 7) and (Length(S) <= 15);
end;

function IsSubnetList(const S: String): Boolean;
begin
  Result := OnlyChars(S, DIGITS + './,') and (Pos('/', S) > 0);
end;

function IsHttpsUrl(const S: String): Boolean;
begin
  Result := (Pos('https://', Lowercase(S)) = 1) and OnlyChars(S, ALNUM + ':/.-_');
end;

function IsToken(const S: String): Boolean;
begin
  Result := OnlyChars(S, ALNUM + '-_');
end;

function UseTailscale: Boolean;
begin
  Result := NetPage.SelectedValueIndex = 1;
end;

procedure CreateNetworkPages(AfterID: Integer);
begin
  NetPage := CreateInputOptionPage(AfterID, 'Network',
    'How does this computer reach the other RD computers?', '', True, False);
  NetPage.Add('My own WireGuard tunnel to home (recommended)');
  NetPage.Add('Tailscale / headscale coordinator');
  NetPage.SelectedValueIndex := 0;

  TsPage := CreateInputQueryPage(NetPage.ID, 'Tailscale', 'Coordinator login',
    'Pre-auth key: docker exec rd-coordinator headscale preauthkeys create ...');
  TsPage.Add('Coordinator URL (https://...):', False);
  TsPage.Add('Pre-auth key:', True);
end;

function CheckTailscalePage: Boolean;
begin
  Result := True;
  if not IsHttpsUrl(Trim(TsPage.Values[0])) then begin
    MsgBox('Type the coordinator URL, e.g. https://rd.example.com', mbError, MB_OK);
    Result := False;
  end else if not IsToken(Trim(TsPage.Values[1])) then begin
    MsgBox('Type the pre-auth key (letters, numbers, - and _ only).', mbError, MB_OK);
    Result := False;
  end;
end;

function TailscaleParams: String;
begin
  Result := ' -Network tailscale -LoginServer "' + Trim(TsPage.Values[0]) + '" -AuthKey "' + Trim(TsPage.Values[1]) + '"';
end;

{ Runs a setup script hidden; on failure shows where the log is. }
function RunSetupScript(const Script, Params, LogFile: String): Boolean;
var
  Code: Integer;
begin
  WizardForm.StatusLabel.Caption := 'Setting up (network, services, USB). This can take a few minutes...';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -File "' + Script + '"' + Params + ' -LogFile "' + LogFile + '"',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
  if not Result then
    MsgBox('Setup step failed. Details: ' + LogFile + #13#10 +
      'Fix the problem, then run this installer again.', mbError, MB_OK);
end;
