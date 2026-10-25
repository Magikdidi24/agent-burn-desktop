#Requires -Version 7.4
# Construit Agent Burn pour Windows : CLI Rust, polices, bundle PyInstaller, selftest, zip portable, installeur.
#   pwsh -File windows\agent-burn\build.ps1 [-SkipCli]
# Idempotent : une étape déjà faite est sautée (venv, polices, CLI à jour) ou écrasée (bundle, zip, setup).
param(
    [switch]$SkipCli  # ne compile pas le CLI : réutilise build\cli tel quel (itérations sans Rust)
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true  # un exe natif en échec arrête le script
$ProgressPreference = 'SilentlyContinue'          # la barre de progression ralentit les téléchargements
Set-Location $PSScriptRoot

# Révision du CLI : install.sh reste la source unique (AB_REV et AB_VER changent ensemble).
$sh = Get-Content -Raw ../../install.sh
$rev = [regex]::Match($sh, '(?m)^AB_REV=(\w+)').Groups[1].Value
$abVer = [regex]::Match($sh, '(?m)^AB_VER="([^"]+)"').Groups[1].Value
$ver = [regex]::Match((Get-Content -Raw app/agentburn/__init__.py), '__version__ = "([^"]+)"').Groups[1].Value
if (-not ($rev -and $abVer -and $ver)) { throw 'AB_REV / AB_VER (install.sh) ou __version__ (app) introuvable' }

# Python : venv local, dépendances épinglées.
$py = "$PSScriptRoot/.venv/Scripts/python.exe"
if (-not (Test-Path $py)) { python -m venv .venv }
& $py -m pip install -q --disable-pip-version-check -r app/requirements.txt pyinstaller==6.22.3

# Polices : JetBrainsMono Nerd Font v3.4.0 comme install.sh (glyphes du QML validés sur cette version), et sa
# licence. Sommes relevées le 2026-10-25 : un fichier de release peut être remplacé après coup.
$fonts = @{
    'JetBrainsMonoNerdFont-Regular.ttf' = '0ec29a68b539ece7078fc714cebff0c0accb2f4948f8f7963d9f5e86633b12d9'
    'JetBrainsMonoNerdFont-Bold.ttf'    = 'e82e27a7f37c9a0a13cc4e417503a149c6a0280586930772d2ebed803159c864'
    'OFL.txt'                           = '30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad'
}
function Test-Sha256($path, $sha) { (Test-Path $path) -and (Get-FileHash $path -Algorithm SHA256).Hash -eq $sha }
if ($fonts.Keys | Where-Object { -not (Test-Sha256 "app/fonts/$_" $fonts[$_]) }) {
    New-Item -ItemType Directory -Force app/fonts, build | Out-Null
    $zipPath = "$PSScriptRoot/build/JetBrainsMono.zip"
    Invoke-WebRequest https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/JetBrainsMono.zip -OutFile $zipPath
    if (-not (Test-Sha256 $zipPath '76f05ff3ace48a464a6ca57977998784ff7bdbb65a6d915d7e401cd3927c493c')) {
        Remove-Item $zipPath
        throw 'JetBrainsMono.zip ne correspond pas à la somme sha256 attendue (release v3.4.0 modifiée ?)'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($f in $fonts.Keys) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry($f), "$PSScriptRoot/app/fonts/$f", $true)
        }
    } finally { $zip.Dispose() }
    Remove-Item $zipPath
    # Zip vérifié : un écart ici est une somme mal relevée, qui ferait retélécharger le zip à chaque build.
    foreach ($f in $fonts.Keys) { if (-not (Test-Sha256 "app/fonts/$f" $fonts[$f])) { throw "app/fonts/$f : somme sha256 inattendue" } }
}

# CLI agent-burn : compilé depuis la source à la révision épinglée, seulement si elle a changé. Témoin
# build\cli\rev plutôt que --version : l'amont corrige le CLI sans changer sa version.
$cli = "$PSScriptRoot/build/cli/bin/agent-burn.exe"
$stamp = "$PSScriptRoot/build/cli/rev"
if (-not $SkipCli -and -not ((Test-Path $cli) -and (Get-Content $stamp -ErrorAction Ignore) -eq $rev)) {
    if (-not (Get-Command cargo -ErrorAction Ignore)) { throw 'cargo introuvable : installe Rust (rustup) ou relance avec -SkipCli' }
    # aws-lc (TLS du CLI) veut NASM, absent de Windows : objets précompilés. CRT statique : l'exe, seul
    # dans bin\ loin des DLL du bundle, tourne sans le Redistribuable Visual C++.
    $env:AWS_LC_SYS_PREBUILT_NASM = '1'
    $env:RUSTFLAGS = '-C target-feature=+crt-static'
    try {
        cargo install --locked --force --git https://github.com/Melvynx/agent-burn --rev $rev agent-burn --bin agent-burn --root "$PSScriptRoot/build/cli"
    } finally { Remove-Item Env:AWS_LC_SYS_PREBUILT_NASM, Env:RUSTFLAGS }
    # AB_VER doit décrire ce CLI : install.sh s'y fie sous Linux pour ne pas le recompiler.
    if ((& $cli --version) -ne $abVer) { throw "Le CLI compilé ne répond pas « $abVer » : AB_REV et AB_VER divergent dans install.sh" }
    Set-Content $stamp $rev
}
# Sinon agentburn.spec l'omet sans rien dire (bundle Linux de test) et l'app installée n'a pas de CLI.
if (-not (Test-Path $cli)) { throw "$cli absent : relance sans -SkipCli (Rust requis)" }

# Bundle onedir → dist\AgentBurn
& $py -m PyInstaller --noconfirm agentburn.spec

# Selftest du bundle gelé : l'exe sert lui-même les fixtures (faux CLI) et ses données vont dans build\,
# jamais dans l'historique réel (%APPDATA%\AgentBurn).
$exe = "$PSScriptRoot/dist/AgentBurn/AgentBurn.exe"
Remove-Item dist/selftest, build/selftest-data -Recurse -Force -ErrorAction Ignore
New-Item -ItemType Directory -Force dist/selftest | Out-Null
$env:AGENT_BURN_FAKE_DIR = "$PSScriptRoot/tests/fixtures"
$env:AGENT_BURN_BIN = $exe
$env:AGENT_BURN_DATA = "$PSScriptRoot/build/selftest-data"
$env:QT_FORCE_STDERR_LOGGING = '1'   # exe fenêtré, sans console : Qt écrirait par OutputDebugString
try {
    # Start-Process : lancée directement, une app fenêtrée rend la main sans attendre sa fin. Son stderr
    # (artefact de la CI) est la seule trace d'un plantage survenu avant selftest.json.
    $p = Start-Process $exe -ArgumentList '--selftest', 'dist/selftest' -WorkingDirectory $PSScriptRoot `
        -RedirectStandardError dist/selftest/stderr.txt -PassThru
    $null = $p.Handle  # sans handle gardé, ExitCode reste vide une fois le processus terminé
    if (-not $p.WaitForExit(300000)) { $p.Kill(); throw 'Selftest bloqué depuis 5 min : processus arrêté' }
} finally {
    Remove-Item Env:AGENT_BURN_FAKE_DIR, Env:AGENT_BURN_BIN, Env:AGENT_BURN_DATA, Env:QT_FORCE_STDERR_LOGGING
}
if ($p.ExitCode -ne 0) { throw "Selftest en échec (code $($p.ExitCode)) : voir dist\selftest\selftest.json et stderr.txt" }

# Zip portable puis installeur Inno Setup (sortie : installer.iss → OutputDir=dist).
Compress-Archive -Path dist/AgentBurn -DestinationPath "dist/AgentBurn-portable-$ver.zip" -Force
$iscc = (Get-Command iscc -ErrorAction Ignore).Source
if (-not $iscc) { $iscc = 'C:/Program Files (x86)/Inno Setup 6/ISCC.exe' }
if (-not (Test-Path $iscc)) { throw 'Inno Setup 6 introuvable (https://jrsoftware.org/isdl.php)' }
& $iscc /Q "/DAppVersion=$ver" installer.iss

Write-Host "OK : dist\AgentBurn-Setup-$ver.exe, dist\AgentBurn-portable-$ver.zip, dist\selftest\"
