; Installeur Agent Burn (Inno Setup 6), compilé par build.ps1 : iscc /DAppVersion=<ver> /DArch=x64|arm64 installer.iss.
; Par utilisateur, sans droits admin. Encodé en UTF-8 avec BOM : sans lui, ISCC lit les accents en ANSI.
#if !defined(AppVersion) || !defined(Arch)
  #error Compiler via build.ps1 (iscc /DAppVersion=<version> /DArch=x64|arm64 installer.iss)
#endif
#if Arch != "x64" && Arch != "arm64"
  #error /DArch : x64 ou arm64
#endif
; Bundle de [Files], parcouru à la compilation pour [InstallDelete].
#define Bundle SourcePath + "dist\AgentBurn\"

[Setup]
; AppId fixe : une nouvelle version remplace l'installation existante au lieu d'en ajouter une.
AppId={{53355E36-C9BA-4551-BBA3-735E495EEBA2}
AppName=Agent Burn
AppVersion={#AppVersion}
AppPublisher=Berthelot Samuel
; Nom dans Paramètres → Applications, sans le « version x.y.z » qu'Inno ajoute par défaut.
UninstallDisplayName=Agent Burn
VersionInfoVersion={#AppVersion}
VersionInfoProductName=Agent Burn
DefaultDirName={localappdata}\Programs\Agent Burn
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
; x64compatible : aussi Windows 11 sur ARM, qui émule le x64.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
; Qt 6 exige Windows 10 1809 ou plus récent.
MinVersion=10.0.17763
OutputDir=dist
OutputBaseFilename=AgentBurn-Setup-{#AppVersion}-{#Arch}
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
Name: "desktopicon"; Description: "Créer un raccourci sur le Bureau"; Flags: unchecked

[InstallDelete]
; Mise à jour : chaque sous-dossier du bundle est vidé avant la copie, sinon ce qu'une version retire y reste
; (plugins Qt, QML, polices chargées par motif). Jamais {app}\* : le dossier choisi peut contenir autre chose.
; shortcut: un fichier racine qu'une ancienne version avait et que celle-ci n'a plus reste jusqu'à la
; désinstallation (python312.dll après un passage à 3.13, inoffensif) ; tout couvrir demanderait un bundle rangé
; dans un seul sous-dossier.
; Seulement par-dessus une installation d'Agent Burn (OwnInstall) : un dossier choisi à la main peut avoir ses
; propres sous-dossiers bin, shared, licenses…
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
; Même valeur « AgentBurn » que celle que l'app active ou retire elle-même.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "AgentBurn"; ValueData: """{app}\AgentBurn.exe"""; Tasks: autostart
; Réactive aussi une entrée désactivée depuis le Gestionnaire des tâches (sinon Windows ne la lance plus).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueType: none; ValueName: "AgentBurn"; Flags: deletevalue; Tasks: autostart
; Sans condition : la désinstallation retire les valeurs même quand c'est l'app (ou Windows) qui les a posées.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "AgentBurn"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueType: none; ValueName: "AgentBurn"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\AgentBurn.exe"; Description: "{cm:LaunchProgram,Agent Burn}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; L'app tourne en fond dans la zone de notification : sans l'arrêter, ses fichiers verrouillés resteraient.
; Par nom d'image, pas par dossier : arrête aussi une copie portable ou un selftest de cet utilisateur (sans
; droits admin, jamais ceux des autres sessions).
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im AgentBurn.exe"; Flags: runhidden; RunOnceId: "StopAgentBurn"

[UninstallDelete]
; Cache QML (recréé au lancement) et journaux. %APPDATA%\AgentBurn (historique, réglages) est gardé : une
; réinstallation le retrouve.
Type: filesandordirs; Name: "{localappdata}\AgentBurn\cache"
Type: filesandordirs; Name: "{localappdata}\AgentBurn\logs"
Type: dirifempty; Name: "{localappdata}\AgentBurn"

[Code]
// {app} vient d'une installation d'Agent Burn : son exe et le journal de désinstallation d'Inno y sont.
function OwnInstall: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\AgentBurn.exe')) and FileExists(ExpandConstant('{app}\unins000.dat'));
end;
