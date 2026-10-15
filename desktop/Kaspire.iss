#ifndef AppVersion
  #define AppVersion "0.1.3"
#endif
#define Bundle "..\dist\Kaspire-Windows-" + AppVersion
[Setup]
AppId={{932962E9-CF1B-4E24-94E1-7F62DE37C54D}
AppName=Kaspire
AppVersion={#AppVersion}
AppPublisher=KaspaHUB21
AppPublisherURL=https://kaspire.kaslab.space/
DefaultDirName={localappdata}\Programs\Kaspire
DefaultGroupName=Kaspire
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=Kaspire-Windows-{#AppVersion}-x64-Setup
SetupIconFile=..\apps\mobile_flutter\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\kaspire.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupMutex=KaspireSetup
; Wallets and recovery journals live in LocalAppData\Kaspire, never {app}.
[Files]
Source: "{#Bundle}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Kaspire"; Filename: "{app}\kaspire.exe"
Name: "{userdesktop}\Kaspire"; Filename: "{app}\kaspire.exe"
[Run]
Filename: "{app}\kaspire.exe"; Description: "Open Kaspire"; Flags: nowait
