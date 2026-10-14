#ifndef AppVersion
  #define AppVersion "1.2.0"
#endif
[Setup]
AppId={{A7A44C37-80F8-488F-A38D-A43A69464851}
AppName=Axiom OS
AppVersion={#AppVersion}
AppPublisher=Pamidu Vidusaka
AppPublisherURL=https://github.com/pamidu1540/axiom-os
AppSupportURL=https://github.com/pamidu1540/axiom-os/issues
DefaultDirName={localappdata}\Programs\AxiomOS
DefaultGroupName=Axiom OS
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
SetupIconFile=axiom.ico
UninstallDisplayIcon={app}\AxiomOS.exe
LicenseFile=..\LICENSE
InfoBeforeFile=..\docs\INSTALL_NOTICE.txt
OutputDir=..\dist
OutputBaseFilename=Axiom-OS-{#AppVersion}-Setup
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
ChangesEnvironment=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked
Name: "userpath"; Description: "Add the axiom command to my user PATH (for new terminals)"; GroupDescription: "Command line:"

[Files]
Source: "..\dist\AxiomOS\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Axiom OS"; Filename: "{app}\AxiomOS.exe"
Name: "{group}\Axiom workspace terminal"; Filename: "{app}\AxiomOS.exe"; Parameters: "--terminal"
Name: "{group}\Quick start"; Filename: "{app}\docs\QUICKSTART.html"
Name: "{autodesktop}\Axiom OS"; Filename: "{app}\AxiomOS.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\AxiomOS.exe"; Description: "Open Axiom OS and choose a workspace"; Flags: nowait postinstall skipifsilent

[Code]
function SplitString(Value, Delimiter: String): TArrayOfString;
var Position, Count: Integer;
begin
  SetArrayLength(Result, 0);
  repeat
    Position := Pos(Delimiter, Value);
    Count := GetArrayLength(Result);
    SetArrayLength(Result, Count + 1);
    if Position > 0 then
    begin
      Result[Count] := Copy(Value, 1, Position - 1);
      Delete(Value, 1, Position);
    end
    else Result[Count] := Value;
  until Position = 0;
end;

function ContainsPath(Value, Entry: String): Boolean;
var Parts: TArrayOfString; I: Integer;
begin
  Result := False;
  Parts := SplitString(Value, ';');
  for I := 0 to GetArrayLength(Parts) - 1 do
    if CompareText(RemoveBackslashUnlessRoot(Trim(Parts[I])), RemoveBackslashUnlessRoot(Entry)) = 0 then
    begin Result := True; Exit; end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var Value, Entry: String;
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('userpath') then
  begin
    Entry := ExpandConstant('{app}');
    RegQueryStringValue(HKCU, 'Environment', 'Path', Value);
    if not ContainsPath(Value, Entry) then
    begin
      if (Value <> '') and (Value[Length(Value)] <> ';') then Value := Value + ';';
      if not RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Value + Entry) then
        RaiseException('Could not update your user PATH. You can open the workspace terminal from Start instead.');
      RegWriteStringValue(HKCU, 'Software\AxiomOS', 'OwnedPath', Entry);
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var Value, Entry, Updated: String; Parts: TArrayOfString; I: Integer;
begin
  if (CurUninstallStep = usUninstall) and RegQueryStringValue(HKCU, 'Software\AxiomOS', 'OwnedPath', Entry) then
  begin
    if CompareText(Entry, ExpandConstant('{app}')) <> 0 then Exit;
    if RegQueryStringValue(HKCU, 'Environment', 'Path', Value) then
    begin
      Parts := SplitString(Value, ';'); Updated := '';
      for I := 0 to GetArrayLength(Parts) - 1 do
        if (Trim(Parts[I]) <> '') and (CompareText(RemoveBackslashUnlessRoot(Trim(Parts[I])), RemoveBackslashUnlessRoot(Entry)) <> 0) then
        begin
          if Updated <> '' then Updated := Updated + ';';
          Updated := Updated + Parts[I];
        end;
      RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Updated);
    end;
    RegDeleteValue(HKCU, 'Software\AxiomOS', 'OwnedPath');
    RegDeleteKeyIfEmpty(HKCU, 'Software\AxiomOS');
  end;
end;
