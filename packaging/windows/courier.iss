; Inno Setup script for the Courier Windows installer.
; Build (from the repo root, after `flutter build windows --release`):
;   iscc /DAppVersion=1.0.0 packaging\windows\courier.iss
; Output: dist\Courier-Setup-<version>-x64.exe

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "Courier"
#define AppExe "courier.exe"
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
; Never change AppId: it is how Windows recognises upgrades of the same app.
AppId={{A1C4EC91-9619-4F6D-9F2F-B123B79ED129}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Fattesingh Rane
AppPublisherURL=https://github.com/ranefattesingh/courier
AppSupportURL=https://github.com/ranefattesingh/courier/issues
AppUpdatesURL=https://github.com/ranefattesingh/courier/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Installs per-user without admin rights by default; users may choose all-users.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
LicenseFile=..\..\LICENSE
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
OutputDir=..\..\dist
OutputBaseFilename=Courier-Setup-{#AppVersion}-x64
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The Flutter release bundle (exe, flutter_windows.dll, plugin DLLs, data\).
; CI also copies the Visual C++ runtime DLLs into this folder so the app runs on
; machines without the VC++ Redistributable installed.
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
