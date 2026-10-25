#Requires -Version 7.4
# Smoke test on a real Windows (CI job): silent installation (files, shortcuts, autostart, uninstall key),
# selftest of the installed exe, tray mode and 2nd launch, uninstallation, then the portable zip.
#   pwsh -File windows\smoke.ps1 -Setup <AgentBurn-Setup-<ver>-<arch>.exe> [-Portable <zip>]
# Exit code 1 at the first failed check. Needs a machine without Agent Burn: the test installs then uninstalls.
param(
    [Parameter(Mandatory)][string]$Setup,
    [string]$Portable
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
trap { Write-Host "FAIL: $($_.Exception.Message)"; exit 1 }
function Check($ok, $what) { if (-not $ok) { throw $what } }
function Get-RegValue($key, $name) { (Get-ItemProperty $key -ErrorAction Ignore).$name }

# Like build.ps1: Start-Process (a windowed app returns at once), handle kept for ExitCode.
function Wait-Exit($p, $seconds, $what) {
    $null = $p.Handle
    if (-not $p.WaitForExit($seconds * 1000)) { $p.Kill($true); throw "${what}: stuck for $seconds s, killed" }
    $p.ExitCode
}

# Selftest of an exe: it serves the fixtures itself (fake CLI), data outside %APPDATA%\AgentBurn.
function Test-Selftest($exe, $name) {
    $dir = New-Item -ItemType Directory -Force "$out\$name"
    $env:AGENT_BURN_BIN = $exe
    $env:AGENT_BURN_DATA = "$dir\data"
    $code = Wait-Exit (Start-Process $exe '--selftest', "`"$dir`"" -RedirectStandardError "$dir\stderr.txt" -PassThru) 300 "Selftest $name"
    $ok = (Test-Path "$dir\selftest.json") -and (Get-Content "$dir\selftest.json" -Raw | ConvertFrom-Json).ok
    Check ($code -eq 0 -and $ok) "Selftest $name failed (code $code): see $dir\selftest.json and stderr.txt"
}

$Setup = (Resolve-Path $Setup).Path
$name = [regex]::Match((Split-Path $Setup -Leaf), '^AgentBurn-Setup-(\d+\.\d+\.\d+)-(x64|arm64)\.exe$')
Check $name.Success "Unexpected installer name: $Setup (AgentBurn-Setup-<version>-<arch>.exe)"
$ver = $name.Groups[1].Value
$out = [IO.Path]::GetFullPath("$PSScriptRoot/../dist/smoke")   # logs and captures: CI artifact
$app = "$env:LOCALAPPDATA\Programs\Agent Burn"
$exe = "$app\AgentBurn.exe"
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{53355E36-C9BA-4551-BBA3-735E495EEBA2}_is1'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$links = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Agent Burn.lnk", (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Agent Burn.lnk')
$data = "$env:APPDATA\AgentBurn"          # history and settings: kept by uninstallation
$local = "$env:LOCALAPPDATA\AgentBurn"    # QML cache and logs: deleted
$bundle = 'AgentBurn.exe', 'bin\agent-burn.exe', 'shared\Burn.qml', 'qml\Main.qml', 'fonts\JetBrainsMonoNerdFont-Regular.ttf',
    'build-info.json', 'licenses\LICENSE-agent-burn.txt', 'licenses\THIRD-PARTY-NOTICES.txt'

# The final uninstallation would delete a real installation, its autostart or its history.
Check (-not ((Test-Path $uninstallKey) -or (Get-Process AgentBurn -ErrorAction Ignore) -or (Get-RegValue $runKey AgentBurn) -or
             (Get-RegValue $approvedKey AgentBurn) -or (Test-Path $data))) `
    'Agent Burn already present (installation, process, autostart or %APPDATA%\AgentBurn): clean machine required'
Remove-Item $local, $out -Recurse -Force -ErrorAction Ignore   # %LOCALAPPDATA%\AgentBurn: cache of the build.ps1 selftest
New-Item -ItemType Directory -Force $out | Out-Null
$env:AGENT_BURN_FAKE_DIR = (Resolve-Path "$PSScriptRoot/../tests/fixtures").Path
$env:QT_FORCE_STDERR_LOGGING = '1'   # windowed exe: stderr, the only trace of a crash

$code = Wait-Exit (Start-Process $Setup '/VERYSILENT', '/SUPPRESSMSGBOXES', '/CURRENTUSER', '/NORESTART',
    '/TASKS=desktopicon,autostart', "/LOG=`"$out\setup.log`"" -PassThru) 600 'Installation'
Check ($code -eq 0) "Installation: code $code (see $out\setup.log)"
foreach ($f in $bundle + 'unins000.exe') { Check (Test-Path "$app\$f") "Missing after installation: $app\$f" }
Check ((Get-Content "$app\build-info.json" -Raw | ConvertFrom-Json).appVersion -eq $ver) "build-info.json: appVersion differs from $ver"
$shell = New-Object -ComObject WScript.Shell
foreach ($lnk in $links) { Check ((Test-Path $lnk) -and $shell.CreateShortcut($lnk).TargetPath -eq $exe) "Shortcut missing or wrong target: $lnk" }
# PowerShell reads “ and ” as string quotes: backtick-escaped to print them.
Check ((Get-RegValue $runKey AgentBurn) -eq "`"$exe`"") "HKCU\…\Run\AgentBurn = `“$(Get-RegValue $runKey AgentBurn)`”, expected `“`"$exe`"`”"
$u = Get-ItemProperty $uninstallKey -ErrorAction Ignore
Check ($u.DisplayName -eq 'Agent Burn' -and $u.DisplayVersion -eq $ver -and $u.Publisher -eq 'Berthelot Samuel') `
    "Uninstall key: DisplayName `“$($u.DisplayName)`”, DisplayVersion `“$($u.DisplayVersion)`”, Publisher `“$($u.Publisher)`”"

Test-Selftest $exe installed

# Tray mode ~10 s: it must keep running and write its QML cache; a 2nd launch hands over to it and exits fast, code 0.
$env:AGENT_BURN_BIN = $exe
$env:AGENT_BURN_DATA = "$out\tray-data"
$tray = Start-Process $exe -PassThru
$null = $tray.Handle
try {
    Start-Sleep 10
    Check (-not $tray.HasExited) "Tray mode stopped before 10 s (code $($tray.ExitCode))"
    Check (Test-Path "$local\cache") "No QML cache in $local\cache"
    $t = [Diagnostics.Stopwatch]::StartNew()
    $code = Wait-Exit (Start-Process $exe -PassThru) 20 '2nd launch'
    Check ($code -eq 0 -and -not $tray.HasExited) "2nd launch: code $code, 1st instance $(if ($tray.HasExited) { 'stopped' } else { 'alive' })"
    Write-Host "2nd launch: code 0 in $($t.ElapsedMilliseconds) ms"

    # Uninstallation with the app running: [UninstallRun] must stop it. Log, data and disabling from
    # Task Manager created by hand: the app does not necessarily write them within 10 s.
    New-Item -Force "$local\logs\smoke.log", "$data\smoke-keep.txt" | Out-Null
    if (-not (Test-Path $approvedKey)) { New-Item $approvedKey -Force | Out-Null }
    New-ItemProperty $approvedKey AgentBurn -PropertyType Binary -Value ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) | Out-Null
    $code = Wait-Exit (Start-Process "$app\unins000.exe" '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        "/LOG=`"$out\uninstall.log`"" -PassThru) 300 'Uninstallation'
    Check ($code -eq 0) "Uninstallation: code $code (see $out\uninstall.log)"
    # unins000.exe relaunches itself from %TEMP% so it can delete itself: wait for the real end.
    for ($i = 0; $i -lt 60 -and ((Test-Path $app) -or (Test-Path $uninstallKey)); $i++) { Start-Sleep 1 }
    Check ($tray.WaitForExit(10000)) "The app is still running after uninstallation ([UninstallRun] taskkill)"
} finally {
    if (-not $tray.HasExited) { $tray.Kill($true) }
}
Check (-not (Test-Path $app)) "Installation folder still there: $app"
foreach ($lnk in $links) { Check (-not (Test-Path $lnk)) "Shortcut still there: $lnk" }
Check (-not ((Get-RegValue $runKey AgentBurn) -or (Get-RegValue $approvedKey AgentBurn))) 'AgentBurn value still in Run or StartupApproved\Run'
Check (-not (Test-Path $uninstallKey)) 'Uninstall key still there'
Check (-not ((Test-Path "$local\cache") -or (Test-Path "$local\logs"))) "Cache or logs still in $local"
Check (Test-Path "$data\smoke-keep.txt") "$data deleted by uninstallation (must be kept)"
Remove-Item $data -Recurse -Force   # created by this test, clean machine

if ($Portable) {
    Expand-Archive $Portable "$out\portable"
    foreach ($f in $bundle) { Check (Test-Path "$out\portable\AgentBurn\$f") "Missing from the portable zip: AgentBurn\$f" }
    Test-Selftest "$out\portable\AgentBurn\AgentBurn.exe" portable-selftest
    Remove-Item $local -Recurse -Force -ErrorAction Ignore   # QML cache of this selftest
}
Write-Host "OK: installation, shortcuts, registry, selftest, tray mode (without system tray), 2nd launch, uninstallation$(if ($Portable) { ', portable zip' })"
