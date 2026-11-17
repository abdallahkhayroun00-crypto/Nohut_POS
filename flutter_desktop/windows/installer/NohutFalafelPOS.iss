#ifndef ReleaseDir
  #error ReleaseDir is required.
#endif
#ifndef InstallerDir
  #error InstallerDir is required.
#endif
#ifndef SetupVersion
  #error SetupVersion is required.
#endif

#define AppTitle "Nohut Falafel POS"
#define AppExe "nohut_falafel_desktop.exe"
; Keep this ID and the per-user install mode across releases.
#define ProductId "NohutFalafel.POS"
#define UninstallKey "Software\Microsoft\Windows\CurrentVersion\Uninstall\" + ProductId + "_is1"

[Setup]
AppId={#ProductId}
AppName={#AppTitle}
AppPublisher=Nohut Falafel
AppVersion={#SetupVersion}
VersionInfoVersion={#SetupVersion}
DefaultDirName={localappdata}\Programs\Nohut Falafel POS
UsePreviousAppDir=yes
DisableDirPage=auto
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
OutputDir={#InstallerDir}
OutputBaseFilename=NohutFalafelPOS-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Files]
Source: "{#ReleaseDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ReleaseDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ReleaseDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#ReleaseDir}\build-manifest.json"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userdesktop}\{#AppTitle}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
Name: "{userprograms}\{#AppTitle}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppTitle}}"; Flags: nowait postinstall skipifsilent

[CustomMessages]
english.NewerInstalled=A newer version of Nohut Falafel POS is already installed.
french.NewerInstalled=Une version plus récente de Nohut Falafel POS est déjà installée.
turkish.NewerInstalled=Nohut Falafel POS'un daha yeni bir sürümü zaten kurulu.

[Code]
function InitializeSetup(): Boolean;
var
  InstalledVersion: String;
  Previous, Current: Int64;
begin
  Result := True;
  if RegQueryStringValue(HKCU, '{#UninstallKey}', 'DisplayVersion', InstalledVersion)
    and StrToVersion(InstalledVersion, Previous)
    and StrToVersion('{#SetupVersion}', Current)
    and (ComparePackedVersion(Previous, Current) > 0) then
  begin
    Log('A newer POS version is installed: ' + InstalledVersion);
    if not WizardSilent then
      MsgBox(CustomMessage('NewerInstalled'), mbError, MB_OK);
    Result := False;
  end;
end;
