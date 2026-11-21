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
; Single-sourced from pubspec.yaml at build time: the workflow passes
; /DMyAppVersion=<version> to iscc (see .github/workflows/windows.yml).
; Without it the fallback below keeps the last released version, so a
; local `iscc windows/installer.iss` still produces the same file.
#ifndef MyAppVersion
  #define MyAppVersion "1.1.5"
#endif
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
OutputBaseFilename=HAoStudio-standalone-v{#MyAppVersion}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
; The choco-installed Inno Setup ships only Default.isl — the Chinese
; translation is NOT in compiler:Languages. The official
; ChineseSimplified.isl (jrsoftware/issrc) is bundled in this repo so
; the CI build does not depend on a separate download:
; windows/installer-languages/ChineseSimplified.isl
Name: "chinesesimp"; MessagesFile: "installer-languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
