#Requires -Version 7.4
# Test de fumée sur un vrai Windows (job CI) : installation silencieuse (fichiers, raccourcis, démarrage auto, clé de
# désinstallation), selftest de l'exe installé, mode tray et 2e lancement, désinstallation, puis le zip portable.
#   pwsh -File windows\smoke.ps1 -Setup <AgentBurn-Setup-<ver>-<arch>.exe> [-Portable <zip>]
# Code 1 au premier contrôle en échec. Machine sans Agent Burn exigée : le test installe puis désinstalle.
param(
    [Parameter(Mandatory)][string]$Setup,
    [string]$Portable
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
trap { Write-Host "ÉCHEC : $($_.Exception.Message)"; exit 1 }
function Check($ok, $what) { if (-not $ok) { throw $what } }
function Get-RegValue($key, $name) { (Get-ItemProperty $key -ErrorAction Ignore).$name }

# Comme build.ps1 : Start-Process (une app fenêtrée rend la main tout de suite), handle gardé pour ExitCode.
function Wait-Exit($p, $seconds, $what) {
    $null = $p.Handle
    if (-not $p.WaitForExit($seconds * 1000)) { $p.Kill($true); throw "$what : bloqué depuis $seconds s, arrêté" }
    $p.ExitCode
}

# Selftest d'un exe : il sert lui-même les fixtures (faux CLI), données hors de %APPDATA%\AgentBurn.
function Test-Selftest($exe, $name) {
    $dir = New-Item -ItemType Directory -Force "$out\$name"
    $env:AGENT_BURN_BIN = $exe
    $env:AGENT_BURN_DATA = "$dir\data"
    $code = Wait-Exit (Start-Process $exe '--selftest', "`"$dir`"" -RedirectStandardError "$dir\stderr.txt" -PassThru) 300 "Selftest $name"
    $ok = (Test-Path "$dir\selftest.json") -and (Get-Content "$dir\selftest.json" -Raw | ConvertFrom-Json).ok
    Check ($code -eq 0 -and $ok) "Selftest $name en échec (code $code) : voir $dir\selftest.json et stderr.txt"
}

$Setup = (Resolve-Path $Setup).Path
$name = [regex]::Match((Split-Path $Setup -Leaf), '^AgentBurn-Setup-(\d+\.\d+\.\d+)-(x64|arm64)\.exe$')
Check $name.Success "Nom d'installeur inattendu : $Setup (AgentBurn-Setup-<version>-<arch>.exe)"
$ver = $name.Groups[1].Value
$out = [IO.Path]::GetFullPath("$PSScriptRoot/../dist/smoke")   # journaux et captures : artefact de la CI
$app = "$env:LOCALAPPDATA\Programs\Agent Burn"
$exe = "$app\AgentBurn.exe"
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{53355E36-C9BA-4551-BBA3-735E495EEBA2}_is1'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$links = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Agent Burn.lnk", (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Agent Burn.lnk')
$data = "$env:APPDATA\AgentBurn"          # historique et réglages : gardés par la désinstallation
$local = "$env:LOCALAPPDATA\AgentBurn"    # cache QML et journaux : effacés
$bundle = 'AgentBurn.exe', 'bin\agent-burn.exe', 'shared\Burn.qml', 'qml\Main.qml', 'fonts\JetBrainsMonoNerdFont-Regular.ttf',
    'build-info.json', 'licenses\LICENSE-agent-burn.txt', 'licenses\THIRD-PARTY-NOTICES.txt'

# La désinstallation finale effacerait une vraie installation, son démarrage auto ou son historique.
Check (-not ((Test-Path $uninstallKey) -or (Get-Process AgentBurn -ErrorAction Ignore) -or (Get-RegValue $runKey AgentBurn) -or
             (Get-RegValue $approvedKey AgentBurn) -or (Test-Path $data))) `
    'Agent Burn déjà présent (installation, processus, démarrage auto ou %APPDATA%\AgentBurn) : machine vierge exigée'
Remove-Item $local, $out -Recurse -Force -ErrorAction Ignore   # %LOCALAPPDATA%\AgentBurn : cache du selftest de build.ps1
New-Item -ItemType Directory -Force $out | Out-Null
$env:AGENT_BURN_FAKE_DIR = (Resolve-Path "$PSScriptRoot/../tests/fixtures").Path
$env:QT_FORCE_STDERR_LOGGING = '1'   # exe fenêtré : stderr, seule trace d'un plantage

$code = Wait-Exit (Start-Process $Setup '/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART',
    '/TASKS=desktopicon,autostart', "/LOG=`"$out\setup.log`"" -PassThru) 600 'Installation'
Check ($code -eq 0) "Installation : code $code (voir $out\setup.log)"
foreach ($f in $bundle + 'unins000.exe') { Check (Test-Path "$app\$f") "Absent après installation : $app\$f" }
Check ((Get-Content "$app\build-info.json" -Raw | ConvertFrom-Json).appVersion -eq $ver) "build-info.json : appVersion différente de $ver"
$shell = New-Object -ComObject WScript.Shell
foreach ($lnk in $links) { Check ((Test-Path $lnk) -and $shell.CreateShortcut($lnk).TargetPath -eq $exe) "Raccourci absent ou cible fausse : $lnk" }
Check ((Get-RegValue $runKey AgentBurn) -eq "`"$exe`"") "HKCU\…\Run\AgentBurn = « $(Get-RegValue $runKey AgentBurn) », attendu « `"$exe`" »"
$u = Get-ItemProperty $uninstallKey -ErrorAction Ignore
Check ($u.DisplayName -eq 'Agent Burn' -and $u.DisplayVersion -eq $ver -and $u.Publisher -eq 'Berthelot Samuel') `
    "Clé de désinstallation : DisplayName « $($u.DisplayName) », DisplayVersion « $($u.DisplayVersion) », Publisher « $($u.Publisher) »"

Test-Selftest $exe installed

# Mode tray ~10 s : il doit tenir et poser son cache QML ; un 2e lancement lui passe la main et sort vite, code 0.
$env:AGENT_BURN_BIN = $exe
$env:AGENT_BURN_DATA = "$out\tray-data"
$tray = Start-Process $exe -PassThru
$null = $tray.Handle
try {
    Start-Sleep 10
    Check (-not $tray.HasExited) "Mode tray arrêté avant 10 s (code $($tray.ExitCode))"
    Check (Test-Path "$local\cache") "Pas de cache QML dans $local\cache"
    $t = [Diagnostics.Stopwatch]::StartNew()
    $code = Wait-Exit (Start-Process $exe -PassThru) 20 '2e lancement'
    Check ($code -eq 0 -and -not $tray.HasExited) "2e lancement : code $code, 1re instance $(if ($tray.HasExited) { 'arrêtée' } else { 'en vie' })"
    Write-Host "2e lancement : code 0 en $($t.ElapsedMilliseconds) ms"

    # Désinstallation app lancée : [UninstallRun] doit l'arrêter. Journal, données et désactivation par le
    # Gestionnaire des tâches posés à la main : l'app n'en écrit pas forcément en 10 s.
    New-Item -Force "$local\logs\smoke.log", "$data\smoke-keep.txt" | Out-Null
    if (-not (Test-Path $approvedKey)) { New-Item $approvedKey -Force | Out-Null }
    New-ItemProperty $approvedKey AgentBurn -PropertyType Binary -Value ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) | Out-Null
    $code = Wait-Exit (Start-Process "$app\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        "/LOG=`"$out\uninstall.log`"" -PassThru) 300 'Désinstallation'
    Check ($code -eq 0) "Désinstallation : code $code (voir $out\uninstall.log)"
    # unins000.exe se relance depuis %TEMP% pour pouvoir s'effacer : attendre la fin réelle.
    for ($i = 0; $i -lt 60 -and ((Test-Path $app) -or (Test-Path $uninstallKey)); $i++) { Start-Sleep 1 }
    Check ($tray.WaitForExit(10000)) "L'app tourne encore après la désinstallation ([UninstallRun] taskkill)"
} finally {
    if (-not $tray.HasExited) { $tray.Kill($true) }
}
Check (-not (Test-Path $app)) "Dossier d'installation encore là : $app"
foreach ($lnk in $links) { Check (-not (Test-Path $lnk)) "Raccourci encore là : $lnk" }
Check (-not ((Get-RegValue $runKey AgentBurn) -or (Get-RegValue $approvedKey AgentBurn))) 'Valeur AgentBurn encore dans Run ou StartupApproved\Run'
Check (-not (Test-Path $uninstallKey)) 'Clé de désinstallation encore là'
Check (-not ((Test-Path "$local\cache") -or (Test-Path "$local\logs"))) "Cache ou journaux encore dans $local"
Check (Test-Path "$data\smoke-keep.txt") "$data effacé par la désinstallation (doit être gardé)"
Remove-Item $data -Recurse -Force   # créé par ce test, machine vierge

if ($Portable) {
    Expand-Archive $Portable "$out\portable"
    foreach ($f in $bundle) { Check (Test-Path "$out\portable\AgentBurn\$f") "Absent du zip portable : AgentBurn\$f" }
    Test-Selftest "$out\portable\AgentBurn\AgentBurn.exe" portable-selftest
    Remove-Item $local -Recurse -Force -ErrorAction Ignore   # cache QML de ce selftest
}
Write-Host "OK : installation, raccourcis, registre, selftest, tray, 2e lancement, désinstallation$(if ($Portable) { ', zip portable' })"
