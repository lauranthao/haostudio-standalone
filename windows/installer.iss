; HAo Studio — Inno Setup installer script (Windows desktop edition).
;
; Built by the GitHub Actions workflow (see
; ~/workspace/research/windows-ci-workflow.yml): `iscc windows/installer.iss`
; after `flutter build windows --release`. Produces
; HAoStudio-standalone-v1.1.5-setup.exe next to the script's OutputDir.
;
; Per-user install (PrivilegesRequired=lowest, {localappdata}\Programs):
; no UAC prompt, no admin needed — chen installs it on his own PC by
; double-clicking. The zip (decompress-and-run) stays the other
; distribution form; the installer only adds Start Menu / desktop
; shortcuts and the Add/Remove-Programs entry.
;
; AppId is fixed forever: changing it would make Windows treat a later
; version as a different app instead of an upgrade.

#define MyAppName "HAo Studio"
#define MyAppVersion "1.1.5"
#define MyAppPublisher "HAo Studio"
#define MyAppExeName "standalone.exe"

[Setup]
AppId={{BBE025F8-74C2-425D-9D39-551200766F7B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
; Relative paths below resolve from THIS script's directory
; (windows/), so the build output is ../build/... — the script is
; run from the repo root as `iscc windows/installer.iss`.
OutputDir=..\build\windows-installer
OutputBaseFilename=HAoStudio-standalone-v1.1.5-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
