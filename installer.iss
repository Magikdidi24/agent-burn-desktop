; Installeur Agent Burn (Inno Setup 6), compilé par build.ps1 : iscc /DAppVersion=<ver> installer.iss.
; Par utilisateur, sans droits admin. Encodé en UTF-8 avec BOM : sans lui, ISCC lit les accents en ANSI.
#ifndef AppVersion
  #error Compiler via build.ps1 (iscc /DAppVersion=<version> installer.iss)
#endif

[Setup]
; AppId fixe : une nouvelle version remplace l'installation existante au lieu d'en ajouter une.
AppId={{53355E36-C9BA-4551-BBA3-735E495EEBA2}
AppName=Agent Burn
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Agent Burn
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Qt 6 exige Windows 10 1809 ou plus récent.
MinVersion=10.0.17763
OutputDir=dist
OutputBaseFilename=AgentBurn-Setup-{#AppVersion}
SetupIconFile=assets\agent-burn.ico
UninstallDisplayIcon={app}\AgentBurn.exe
WizardStyle=modern
SolidCompression=yes
; Mise à jour : l'app de la zone de notification n'a pas de fenêtre à qui demander de quitter.
CloseApplications=force

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "autostart"; Description: "Lancer Agent Burn au démarrage de Windows"

[Files]
Source: "dist\AgentBurn\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\Agent Burn"; Filename: "{app}\AgentBurn.exe"

[Registry]
; Même valeur « AgentBurn » que celle que l'app active ou retire elle-même.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "AgentBurn"; ValueData: """{app}\AgentBurn.exe"""; Tasks: autostart
; Réactive aussi une entrée désactivée depuis le Gestionnaire des tâches (sinon Windows ne la lance plus).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueType: none; ValueName: "AgentBurn"; Flags: deletevalue; Tasks: autostart
; Sans condition : la désinstallation retire la valeur même quand c'est l'app qui l'a posée.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "AgentBurn"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\AgentBurn.exe"; Description: "{cm:LaunchProgram,Agent Burn}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; L'app tourne en fond dans la zone de notification : sans l'arrêter, ses fichiers verrouillés resteraient.
; Rien dans [UninstallDelete] : l'historique (%APPDATA%\AgentBurn) survit à la désinstallation.
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im AgentBurn.exe"; Flags: runhidden; RunOnceId: "StopAgentBurn"
