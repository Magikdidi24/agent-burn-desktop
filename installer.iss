; Agent Burn installer (Inno Setup 6), compiled by build.ps1: iscc /DAppVersion=<ver> /DArch=x64|arm64 installer.iss.
; Per user, without admin rights. Encoded in UTF-8 with BOM: without it, ISCC reads non-ASCII characters as ANSI.
#if !defined(AppVersion) || !defined(Arch)
  #error Build through build.ps1 (iscc /DAppVersion=<version> /DArch=x64|arm64 installer.iss)
#endif
#if Arch != "x64" && Arch != "arm64"
  #error /DArch: x64 or arm64
#endif
; [Files] bundle, scanned at compile time for [InstallDelete].
#define Bundle SourcePath + "dist\AgentBurn\"

[Setup]
; Fixed AppId: a new version replaces the existing installation instead of adding another one.
AppId={{53355E36-C9BA-4551-BBA3-735E495EEBA2}
AppName=Agent Burn
AppVersion={#AppVersion}
AppPublisher=Berthelot Samuel
; Name in Settings → Apps, without the "version x.y.z" that Inno adds by default.
UninstallDisplayName=Agent Burn
VersionInfoVersion={#AppVersion}
VersionInfoProductName=Agent Burn
DefaultDirName={localappdata}\Programs\Agent Burn
; No folder choice: an existing folder picked by hand would be emptied by [InstallDelete] on the next update
; (OwnInstall would become true there). /DIR= remains possible on the command line.
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
; x64compatible: also Windows 11 on ARM, which emulates x64.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
; Qt 6 requires Windows 10 1809 or later.
MinVersion=10.0.17763
OutputDir=dist
OutputBaseFilename=AgentBurn-Setup-{#AppVersion}-{#Arch}
SetupIconFile=assets\agent-burn.ico
UninstallDisplayIcon={app}\AgentBurn.exe
WizardStyle=modern
SolidCompression=yes
; Update: the system tray app has no window to ask to quit.
CloseApplications=force

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; Description: "Start Agent Burn at Windows startup"
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[InstallDelete]
; Update: every bundle subfolder is emptied before the copy, otherwise what a version removes stays there
; (Qt plugins, QML, fonts loaded by pattern). Never {app}\*: the chosen folder may contain something else.
; shortcut: a root file that an older version had and this one no longer has stays until uninstallation
; (python312.dll after a move to 3.13, harmless); covering everything would need a bundle kept in a single
; subfolder.
; Only over an Agent Burn installation (OwnInstall): a folder chosen by hand can have its own bin, shared,
; licenses… subfolders.
#define FindHandle
#define FindResult
#sub DeleteBundleDir
  #define Name FindGetFileName(FindHandle)
  #if Name != "." && Name != ".." && DirExists(Bundle + Name)
Type: filesandordirs; Name: "{app}\{#Name}"; Check: OwnInstall
  #endif
#endsub
#for {FindHandle = FindResult = FindFirst(Bundle + "*", faDirectory); FindResult; FindResult = FindNext(FindHandle)} DeleteBundleDir
#if FindHandle
  #expr FindClose(FindHandle)
#endif

[Files]
Source: "dist\AgentBurn\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Agent Burn"; Filename: "{app}\AgentBurn.exe"
Name: "{userdesktop}\Agent Burn"; Filename: "{app}\AgentBurn.exe"; Tasks: desktopicon

[Registry]
; Same "AgentBurn" value as the one the app itself sets or removes.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "AgentBurn"; ValueData: """{app}\AgentBurn.exe"""; Tasks: autostart
; Also re-enables an entry disabled from Task Manager (otherwise Windows no longer starts it).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueType: none; ValueName: "AgentBurn"; Flags: deletevalue; Tasks: autostart
; Unconditional: uninstallation removes the values even when the app (or Windows) set them.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "AgentBurn"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueType: none; ValueName: "AgentBurn"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\AgentBurn.exe"; Description: "{cm:LaunchProgram,Agent Burn}"; Flags: nowait postinstall skipifsilent
; Silent update started by the app (updater.py), which quit for it: started again. Other silent installs do not.
Filename: "{app}\AgentBurn.exe"; Flags: nowait; Check: Relaunch

[UninstallRun]
; The app runs in the background in the system tray: without stopping it, its locked files would stay.
; By image name, not by folder: also stops a portable copy or a selftest of this user (without admin
; rights, never those of other sessions).
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im AgentBurn.exe"; Flags: runhidden; RunOnceId: "StopAgentBurn"

[UninstallDelete]
; QML cache (recreated at launch) and logs. %APPDATA%\AgentBurn (history, settings) is kept: a reinstallation
; finds it again.
Type: filesandordirs; Name: "{localappdata}\AgentBurn\cache"
Type: filesandordirs; Name: "{localappdata}\AgentBurn\logs"
Type: dirifempty; Name: "{localappdata}\AgentBurn"

[Code]
// {app} comes from an Agent Burn installation: its exe and Inno's uninstall log are there.
function OwnInstall: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\AgentBurn.exe')) and FileExists(ExpandConstant('{app}\unins000.dat'));
end;

// /relaunch=1 on the command line: the app started this update and quit to let it replace its files.
function Relaunch: Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;
