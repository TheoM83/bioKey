#define AppName "BioKey"
#define AppVersion GetEnv("BIOKEY_VERSION")
#if AppVersion == ""
  #error BIOKEY_VERSION non défini — lancez tool/build_release.ps1
#endif
#define AppExe "biokey.exe"

[Setup]
AppId={{4A3D03B0-8FE0-4B2A-8A9E-9898F5832791}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Opsidious
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=BioKey-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExe}
CloseApplications=yes

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"

[Run]
Filename: "{app}\{#AppExe}"; Description: "Lancer BioKey"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "taskkill"; Parameters: "/IM {#AppExe} /F"; Flags: runhidden; RunOnceId: "killbiokey"
