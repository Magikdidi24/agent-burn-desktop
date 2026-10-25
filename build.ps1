#Requires -Version 7.4
# Construit Agent Burn pour Windows : CLI Rust, polices, licences, bundle PyInstaller, selftest, zip portable, installeur.
#   pwsh -File desktop\agent-burn\build.ps1 [-Arch x64|arm64] [-SkipCli]
# Idempotent : une étape déjà faite est sautée (venv, polices, CLI à jour) ou écrasée (bundle, zip, setup).
param(
    # Sans compilation croisée : la machine et son Python doivent être de cette architecture (PyInstaller gèle la sienne).
    [ValidateSet('x64', 'arm64', IgnoreCase = $false)][string]$Arch = 'x64',
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
# X.Y.Z : les ressources de version Windows (exe, installeur) n'acceptent que des nombres.
$ver = [regex]::Match((Get-Content -Raw app/agentburn/__init__.py), '__version__ = "(\d+\.\d+\.\d+)"').Groups[1].Value
if (-not ($rev -and $abVer -and $ver)) { throw 'AB_REV / AB_VER (install.sh) ou __version__ X.Y.Z (app) introuvable' }
$target = @{ x64 = 'x86_64-pc-windows-msvc'; arm64 = 'aarch64-pc-windows-msvc' }[$Arch]

# Python : venv local, dépendances épinglées.
$py = "$PSScriptRoot/.venv/Scripts/python.exe"
if (-not (Test-Path $py)) { python -m venv .venv }
$pyPlatform = & $py -c 'import sysconfig; print(sysconfig.get_platform())'
if ($pyPlatform -ne @{ x64 = 'win-amd64'; arm64 = 'win-arm64' }[$Arch]) {
    throw "Python $pyPlatform pour -Arch $Arch : supprime .venv et relance avec un Python $Arch dans le PATH"
}
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

# CLI agent-burn : compilé depuis une copie superficielle de l'amont à la révision épinglée, seulement si elle ou la
# cible a changé. Témoin build\cli\rev plutôt que --version : l'amont corrige le CLI sans changer sa version. La copie
# fournit aussi sa licence et son Cargo.lock (notices tierces), gardées dans build\cli avec l'exe (cache de la CI).
$cli = "$PSScriptRoot/build/cli/bin/agent-burn.exe"
$stamp = "$PSScriptRoot/build/cli/rev"
$cliLicense = "$PSScriptRoot/build/cli/LICENSE-agent-burn.txt"
$cliNotices = "$PSScriptRoot/build/cli/THIRD-PARTY-NOTICES.txt"
$cliFiles = $cli, $stamp, $cliLicense, $cliNotices
if (-not $SkipCli -and -not ((Test-Path $cliFiles) -notcontains $false -and (Get-Content $stamp) -eq "$rev $target")) {
    foreach ($tool in 'git', 'cargo') {
        if (-not (Get-Command $tool -ErrorAction Ignore)) { throw "$tool introuvable : installe Git et Rust (rustup) ou relance avec -SkipCli" }
    }
    # Dans %TEMP% comme cargo install : chemins courts pour les compilations C (aws-lc, SQLite), quelques centaines
    # de Mo effacés après.
    $src = Join-Path ([IO.Path]::GetTempPath()) 'agent-burn-cli'
    Remove-Item $src -Recurse -Force -ErrorAction Ignore
    git init -q $src
    git -C $src fetch -q --depth 1 https://github.com/Melvynx/agent-burn $rev
    git -C $src -c core.autocrlf=false checkout -q FETCH_HEAD
    # aws-lc (TLS du CLI) veut NASM, absent de Windows : objets précompilés. CRT statique : l'exe, seul
    # dans bin\ loin des DLL du bundle, tourne sans le Redistribuable Visual C++.
    $env:AWS_LC_SYS_PREBUILT_NASM = '1'
    $env:RUSTFLAGS = '-C target-feature=+crt-static'
    # Depuis la copie : son rust-toolchain.toml (version de Rust) et son .cargo/config.toml (options SQLite) s'appliquent.
    Push-Location "$src/rust"
    try {
        cargo build --release --locked -p agent-burn --bin agent-burn --target $target --target-dir "$src/target"
    } finally { Pop-Location; Remove-Item Env:AWS_LC_SYS_PREBUILT_NASM, Env:RUSTFLAGS }
    New-Item -ItemType Directory -Force (Split-Path $cli) | Out-Null
    Copy-Item "$src/target/$target/release/agent-burn.exe" $cli
    # AB_VER doit décrire ce CLI : install.sh s'y fie sous Linux pour ne pas le recompiler.
    if ((& $cli --version) -ne $abVer) { throw "Le CLI compilé ne répond pas « $abVer » : AB_REV et AB_VER divergent dans install.sh" }
    Copy-Item "$src/apps/agent-burn/LICENSE" $cliLicense
    & $py tools/third_party_notices.py $src $cliNotices --target $target
    Set-Content $stamp "$rev $target"
    Remove-Item $src -Recurse -Force
}
# Sinon agentburn.spec omet le CLI sans rien dire (bundle Linux de test) et l'app installée n'a pas de CLI.
if (-not ((Test-Path $cliFiles) -notcontains $false -and (Get-Content $stamp) -match " $target$")) {
    throw "build\cli incomplet ou compilé pour une autre cible que $target : relance sans -SkipCli (Git et Rust requis)"
}

# Fichiers ajoutés à la racine du bundle (build\bundle-extra, repris par agentburn.spec) : licences et build-info.json.
# Recréés à chaque build : rien d'un build précédent ne traîne.
$extra = "$PSScriptRoot/build/bundle-extra"
Remove-Item $extra -Recurse -Force -ErrorAction Ignore
New-Item -ItemType Directory -Force "$extra/licenses" | Out-Null
Copy-Item $cliLicense, $cliNotices, tools/licenses/LGPL-3.0.txt, tools/licenses/GPL-3.0.txt "$extra/licenses"
Copy-Item app/fonts/OFL.txt "$extra/licenses/LICENSE-JetBrainsMono-NerdFont.txt"
# Python et les bibliothèques C de sa distribution (OpenSSL, libffi…) ; sous Windows, LICENSE.txt est à sa racine.
Copy-Item (Join-Path (& $py -c 'import sys; print(sys.base_prefix)') LICENSE.txt) "$extra/licenses/LICENSE-Python.txt"
# Qt et PySide6 (LGPL v3) : leurs wheels ne livrent que la notice commerciale ; versions lues dans le venv.
$pyside, $qt = & $py -c 'import PySide6, PySide6.QtCore as c; print(PySide6.__version__); print(c.qVersion())'
(Get-Content -Raw tools/licenses/NOTICE-Qt-PySide6.txt) -replace '@QT@', $qt -replace '@PYSIDE6@', $pyside |
    Set-Content -NoNewline "$extra/licenses/NOTICE-Qt-PySide6.txt"
[ordered]@{
    appVersion = $ver
    cliRev     = (Get-Content $stamp) -replace ' .*'   # celui de build\cli, même avec -SkipCli
    cliVersion = & $cli --version
    target     = $target
    builtAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
} | ConvertTo-Json | Set-Content "$extra/build-info.json"

# Ressource de version de AgentBurn.exe (Propriétés → Détails, nom dans le Gestionnaire des tâches), reprise par
# agentburn.spec.
$nums = ($ver -split '\.') + '0' -join ', '
@"
VSVersionInfo(
  ffi=FixedFileInfo(filevers=($nums), prodvers=($nums)),
  kids=[
    StringFileInfo([StringTable('040C04B0', [
      StringStruct('CompanyName', 'Berthelot Samuel'),
      StringStruct('FileDescription', 'Agent Burn'),
      StringStruct('FileVersion', '$ver'),
      StringStruct('InternalName', 'AgentBurn'),
      StringStruct('LegalCopyright', '© 2026 Berthelot Samuel'),
      StringStruct('OriginalFilename', 'AgentBurn.exe'),
      StringStruct('ProductName', 'Agent Burn'),
      StringStruct('ProductVersion', '$ver')])]),
    VarFileInfo([VarStruct('Translation', [0x040C, 1200])])])
"@ | Set-Content build/version_info.txt

# Bundle onedir → dist\AgentBurn
& $py -m PyInstaller --noconfirm agentburn.spec
# Contrat avec agentburn.spec : sans lui, un bundle sans licences ni version partirait quand même.
foreach ($f in Get-ChildItem $extra -Recurse -File) {
    $rel = [IO.Path]::GetRelativePath($extra, $f.FullName)
    if (-not (Test-Path "dist/AgentBurn/$rel")) { throw "agentburn.spec n'a pas repris build\bundle-extra : $rel absent du bundle" }
}
if ((Get-Item dist/AgentBurn/AgentBurn.exe).VersionInfo.ProductVersion -ne $ver) {
    throw "agentburn.spec n'a pas repris build\version_info.txt : AgentBurn.exe sans version $ver"
}

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

# Zip portable puis installeur Inno Setup (sortie : installer.iss → OutputDir=dist). Noms attendus par la CI.
Compress-Archive -Path dist/AgentBurn -DestinationPath "dist/AgentBurn-portable-$ver-$Arch.zip" -Force
$iscc = (Get-Command iscc -ErrorAction Ignore).Source
if (-not $iscc) { $iscc = 'C:/Program Files (x86)/Inno Setup 6/ISCC.exe' }
if (-not (Test-Path $iscc)) { throw 'Inno Setup 6 introuvable (https://jrsoftware.org/isdl.php)' }
& $iscc /Q "/DAppVersion=$ver" "/DArch=$Arch" installer.iss

Write-Host "OK : dist\AgentBurn-Setup-$ver-$Arch.exe, dist\AgentBurn-portable-$ver-$Arch.zip, dist\selftest\"
