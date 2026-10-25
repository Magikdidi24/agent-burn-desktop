#Requires -Version 7.4
# Builds Agent Burn for Windows: Rust CLI, fonts, licenses, PyInstaller bundle, selftest, portable zip, installer.
#   pwsh -File build.ps1 [-Arch x64|arm64] [-SkipCli]
# Idempotent: a step already done is skipped (venv, fonts, up-to-date CLI) or overwritten (bundle, zip, setup).
param(
    # No cross-compilation: the machine and its Python must be of this architecture (PyInstaller freezes its own).
    [ValidateSet('x64', 'arm64', IgnoreCase = $false)][string]$Arch = 'x64',
    [switch]$SkipCli  # does not build the CLI: reuses build\cli as is (iterations without Rust)
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true  # a failing native exe stops the script
$ProgressPreference = 'SilentlyContinue'          # the progress bar slows down downloads
Set-Location $PSScriptRoot
# Timing markers like linux/build.sh ("== [Ns] step"): each step of the CI log shows its cost.
$sw = [Diagnostics.Stopwatch]::StartNew()
function Step($what) { Write-Host "`n== [$([int]$sw.Elapsed.TotalSeconds)s] $what" }

# CLI revision: cli.env, single source (AB_REV and AB_VER change together).
$pin = Get-Content -Raw cli.env
$rev = [regex]::Match($pin, '(?m)^AB_REV=(\w+)').Groups[1].Value
$abVer = [regex]::Match($pin, '(?m)^AB_VER="([^"]+)"').Groups[1].Value
# X.Y.Z: Windows version resources (exe, installer) accept only numbers.
$ver = [regex]::Match((Get-Content -Raw app/agentburn/__init__.py), '__version__ = "(\d+\.\d+\.\d+)"').Groups[1].Value
if (-not ($rev -and $abVer -and $ver)) { throw 'AB_REV / AB_VER (cli.env) or __version__ X.Y.Z (app) not found' }
$target = @{ x64 = 'x86_64-pc-windows-msvc'; arm64 = 'aarch64-pc-windows-msvc' }[$Arch]

Step 'Python: venv, PySide6, PyInstaller'
# Python: local venv, dependencies from the hashed lock (versions and sha256 of the whole tree, PyInstaller included).
$py = "$PSScriptRoot/.venv/Scripts/python.exe"
if (-not (Test-Path $py)) { python -m venv .venv }
$pyPlatform = & $py -c 'import sysconfig; print(sysconfig.get_platform())'
if ($pyPlatform -ne @{ x64 = 'win-amd64'; arm64 = 'win-arm64' }[$Arch]) {
    throw "Python $pyPlatform for -Arch ${Arch}: delete .venv and rerun with a $Arch Python on the PATH"
}
& $py -m pip install -q --disable-pip-version-check --require-hashes -r app/requirements.lock

Step 'JetBrainsMono Nerd Font v3.4.0 fonts'
# Fonts: JetBrainsMono Nerd Font v3.4.0 like linux/build.sh (QML glyphs validated on this version), and its
# license. Sums recorded on 2026-10-25: a release file can be replaced afterwards.
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
        throw 'JetBrainsMono.zip does not match the expected sha256 sum (v3.4.0 release modified?)'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($f in $fonts.Keys) {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry($f), "$PSScriptRoot/app/fonts/$f", $true)
        }
    } finally { $zip.Dispose() }
    Remove-Item $zipPath
    # Zip verified: a mismatch here is a wrongly recorded sum, which would download the zip again on every build.
    foreach ($f in $fonts.Keys) { if (-not (Test-Sha256 "app/fonts/$f" $fonts[$f])) { throw "app/fonts/${f}: unexpected sha256 sum" } }
}

Step "CLI $abVer ($rev)"
# agent-burn CLI: built from a shallow upstream copy at the pinned revision, only if the revision or the target
# changed. Marker build\cli\rev rather than --version: upstream fixes the CLI without changing its version. The copy
# also provides its license and its Cargo.lock (third-party notices), kept in build\cli with the exe (CI cache).
$cli = "$PSScriptRoot/build/cli/bin/agent-burn.exe"
$stamp = "$PSScriptRoot/build/cli/rev"
$cliLicense = "$PSScriptRoot/build/cli/LICENSE-agent-burn.txt"
$cliNotices = "$PSScriptRoot/build/cli/THIRD-PARTY-NOTICES.txt"
$cliFiles = $cli, $stamp, $cliLicense, $cliNotices
if (-not $SkipCli -and -not ((Test-Path $cliFiles) -notcontains $false -and (Get-Content $stamp) -eq "$rev $target")) {
    foreach ($tool in 'git', 'cargo') {
        if (-not (Get-Command $tool -ErrorAction Ignore)) { throw "$tool not found: install Git and Rust (rustup) or rerun with -SkipCli" }
    }
    # In %TEMP% like cargo install: short paths for the C builds (aws-lc, SQLite), a few hundred MB deleted
    # afterwards.
    $src = Join-Path ([IO.Path]::GetTempPath()) 'agent-burn-cli'
    Remove-Item $src -Recurse -Force -ErrorAction Ignore
    git init -q $src
    git -C $src fetch -q --depth 1 https://github.com/Melvynx/agent-burn $rev
    git -C $src -c core.autocrlf=false checkout -q FETCH_HEAD
    # aws-lc (the CLI's TLS) wants NASM, missing on Windows: prebuilt objects. Static CRT: the exe, alone
    # in bin\ away from the bundle DLLs, runs without the Visual C++ Redistributable.
    $env:AWS_LC_SYS_PREBUILT_NASM = '1'
    $env:RUSTFLAGS = '-C target-feature=+crt-static'
    # From the copy: its rust-toolchain.toml (Rust version) and its .cargo/config.toml (SQLite options) apply.
    Push-Location "$src/rust"
    try {
        cargo build --release --locked -p agent-burn --bin agent-burn --target $target --target-dir "$src/target"
    } finally { Pop-Location; Remove-Item Env:AWS_LC_SYS_PREBUILT_NASM, Env:RUSTFLAGS }
    New-Item -ItemType Directory -Force (Split-Path $cli) | Out-Null
    Copy-Item "$src/target/$target/release/agent-burn.exe" $cli
    # AB_VER must describe this CLI: a mismatch means AB_REV changed without AB_VER.
    # PowerShell reads “ and ” as string quotes: backtick-escaped to print them.
    if ((& $cli --version) -ne $abVer) { throw "The compiled CLI does not answer `“$abVer`”: AB_REV and AB_VER disagree in cli.env" }
    Copy-Item "$src/apps/agent-burn/LICENSE" $cliLicense
    & $py tools/third_party_notices.py $src $cliNotices --target $target
    Set-Content $stamp "$rev $target"
    Remove-Item $src -Recurse -Force
}
# Otherwise agentburn.spec silently leaves out the CLI (Linux test bundle) and the installed app has no CLI.
if (-not ((Test-Path $cliFiles) -notcontains $false -and (Get-Content $stamp) -match " $target$")) {
    throw "build\cli incomplete or built for a target other than ${target}: rerun without -SkipCli (Git and Rust required)"
}

Step 'Licenses, build-info.json, version resource'
# Files added to the bundle root (build\bundle-extra, picked up by agentburn.spec): licenses and build-info.json.
# Recreated on every build: nothing from a previous build lingers.
$extra = "$PSScriptRoot/build/bundle-extra"
Remove-Item $extra -Recurse -Force -ErrorAction Ignore
New-Item -ItemType Directory -Force "$extra/licenses" | Out-Null
Copy-Item $cliLicense, $cliNotices, tools/licenses/LGPL-3.0.txt, tools/licenses/GPL-3.0.txt "$extra/licenses"
Copy-Item LICENSE "$extra/licenses/LICENSE-agent-burn-desktop.txt"
Copy-Item app/fonts/OFL.txt "$extra/licenses/LICENSE-JetBrainsMono-NerdFont.txt"
# Qt and PySide6 (LGPL v3): their wheels ship only the commercial notice; versions read from the venv.
$pyside, $qt, $pyVer = & $py -c 'import sys, PySide6, PySide6.QtCore as c; print(PySide6.__version__); print(c.qVersion()); print(*sys.version_info[:2], sep=chr(46))'
(Get-Content -Raw tools/licenses/NOTICE-Qt-PySide6.txt) -replace '@QT@', $qt -replace '@PYSIDE6@', $pyside |
    Set-Content -NoNewline "$extra/licenses/NOTICE-Qt-PySide6.txt"
# Qt third-party components and software incorporated in Python: collected for these versions, redo when they change.
$qtThird = Get-Content -Raw tools/licenses/QT-THIRD-PARTY.txt
$pyThird = Get-Content -Raw "tools/licenses/PYTHON-$pyVer-THIRD-PARTY.txt"   # one notice per shipped minor version
if (-not $qtThird.StartsWith("Qt $qt and PySide6 ${pyside}:")) { throw "tools\licenses\QT-THIRD-PARTY.txt does not describe Qt $qt and PySide6 ${pyside}: redo it" }
if (-not $pyThird.StartsWith("Python ${pyVer}:")) { throw "tools\licenses\PYTHON-$pyVer-THIRD-PARTY.txt does not describe Python ${pyVer}: redo it" }
Copy-Item tools/licenses/QT-THIRD-PARTY.txt "$extra/licenses"
# Python and the C libraries of its distribution (OpenSSL, libffi…): LICENSE.txt, at its root on Windows, without
# the incorporated software of Doc/license.rst, appended after it.
$pyLicense = Get-Content -Raw (Join-Path (& $py -c 'import sys; print(sys.base_prefix)') LICENSE.txt)
if (-not $pyLicense.Contains('Licenses and Acknowledgements for Incorporated Software')) { $pyLicense += "`n`n$pyThird" }
$pyLicense | Set-Content -NoNewline "$extra/licenses/LICENSE-Python.txt"
[ordered]@{
    appVersion = $ver
    cliRev     = (Get-Content $stamp) -replace ' .*'   # the one in build\cli, even with -SkipCli
    cliVersion = & $cli --version
    target     = "windows-$Arch"
    cliTarget  = $target
    builtAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
} | ConvertTo-Json | Set-Content "$extra/build-info.json"

# Version resource of AgentBurn.exe (Properties → Details, name in Task Manager), picked up by
# agentburn.spec.
$nums = ($ver -split '\.') + '0' -join ', '
@"
VSVersionInfo(
  ffi=FixedFileInfo(filevers=($nums), prodvers=($nums)),
  kids=[
    StringFileInfo([StringTable('040904B0', [
      StringStruct('CompanyName', 'Berthelot Samuel'),
      StringStruct('FileDescription', 'Agent Burn'),
      StringStruct('FileVersion', '$ver'),
      StringStruct('InternalName', 'AgentBurn'),
      StringStruct('LegalCopyright', '© 2026 Berthelot Samuel'),
      StringStruct('OriginalFilename', 'AgentBurn.exe'),
      StringStruct('ProductName', 'Agent Burn'),
      StringStruct('ProductVersion', '$ver')])]),
    VarFileInfo([VarStruct('Translation', [0x0409, 1200])])])
"@ | Set-Content build/version_info.txt

Step 'PyInstaller bundle'
# onedir bundle → dist\AgentBurn
& $py -m PyInstaller --noconfirm agentburn.spec
# Contract with agentburn.spec: without it, a bundle without licenses or version would still ship.
foreach ($f in Get-ChildItem $extra -Recurse -File) {
    $rel = [IO.Path]::GetRelativePath($extra, $f.FullName)
    if (-not (Test-Path "dist/AgentBurn/$rel")) { throw "agentburn.spec did not pick up build\bundle-extra: $rel missing from the bundle" }
}
if ((Get-Item dist/AgentBurn/AgentBurn.exe).VersionInfo.ProductVersion -ne $ver) {
    throw "agentburn.spec did not pick up build\version_info.txt: AgentBurn.exe has no version $ver"
}

Step 'Frozen bundle selftest'
# Frozen bundle selftest: the exe serves the fixtures itself (fake CLI) and its data goes to build\,
# never to the real history (%APPDATA%\AgentBurn).
$exe = "$PSScriptRoot/dist/AgentBurn/AgentBurn.exe"
Remove-Item dist/selftest, build/selftest-data -Recurse -Force -ErrorAction Ignore
New-Item -ItemType Directory -Force dist/selftest | Out-Null
$env:AGENT_BURN_FAKE_DIR = "$PSScriptRoot/tests/fixtures"
$env:AGENT_BURN_BIN = $exe
$env:AGENT_BURN_DATA = "$PSScriptRoot/build/selftest-data"
$env:QT_FORCE_STDERR_LOGGING = '1'   # windowed exe, without a console: Qt would write through OutputDebugString
try {
    # Start-Process: launched directly, a windowed app returns without waiting for its end. Its stderr
    # (CI artifact) is the only trace of a crash that happens before selftest.json.
    $p = Start-Process $exe -ArgumentList '--selftest', 'dist/selftest' -WorkingDirectory $PSScriptRoot `
        -RedirectStandardError dist/selftest/stderr.txt -PassThru
    $null = $p.Handle  # without a kept handle, ExitCode stays empty once the process has ended
    if (-not $p.WaitForExit(300000)) { $p.Kill(); throw 'Selftest stuck for 5 min: process killed' }
} finally {
    Remove-Item Env:AGENT_BURN_FAKE_DIR, Env:AGENT_BURN_BIN, Env:AGENT_BURN_DATA, Env:QT_FORCE_STDERR_LOGGING
}
if ($p.ExitCode -ne 0) { throw "Selftest failed (code $($p.ExitCode)): see dist\selftest\selftest.json and stderr.txt" }

# Portable zip, then Inno Setup installer (output: installer.iss → OutputDir=dist). Names expected by CI.
Step 'Portable zip'
Compress-Archive -Path dist/AgentBurn -DestinationPath "dist/AgentBurn-portable-$ver-$Arch.zip" -Force
Step 'Inno Setup installer'
$iscc = (Get-Command iscc -ErrorAction Ignore).Source
if (-not $iscc) { $iscc = 'C:/Program Files (x86)/Inno Setup 6/ISCC.exe' }
if (-not (Test-Path $iscc)) { throw 'Inno Setup 6 not found (https://jrsoftware.org/isdl.php)' }
# No /Q, which also hides the warnings: we keep the compiler version, the warnings and the
# duration, without the list of compressed files (errors on stderr, code ≠ 0 fatal).
& $iscc "/DAppVersion=$ver" "/DArch=$Arch" installer.iss |
    Where-Object { $_ -match '^(Warning: |Compiler engine version|Successful compile)' }

Step "OK: dist\AgentBurn-Setup-$ver-$Arch.exe, dist\AgentBurn-portable-$ver-$Arch.zip, dist\selftest\"
