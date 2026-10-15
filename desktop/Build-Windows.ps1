param([switch]$SkipChecks)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Run this build script on Windows 10/11 x64.'
}
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$AppRoot = Join-Path $ProjectRoot 'apps\mobile_flutter'
$DesktopRelease = Get-Content (Join-Path $PSScriptRoot 'version.json') -Raw | ConvertFrom-Json
$DesktopVersion = [string]$DesktopRelease.version
$DesktopBuild = [string]$DesktopRelease.build
$LogFile = Join-Path $PSScriptRoot 'build-windows.log'

function Invoke-BuildCommand([string]$Program, [string[]]$Arguments) {
    Write-Host ("`n> " + $Program + ' ' + ($Arguments -join ' '))
    $PreviousErrorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 treats native stderr (including Cargo's normal
        # progress output) as ErrorRecords. The exit status decides success.
        $ErrorActionPreference = 'Continue'
        & $Program @Arguments 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Host
        $CommandExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $PreviousErrorPreference }
    if ($CommandExit -ne 0) {
        throw "Command failed ($CommandExit): $Program. See desktop\build-windows.log."
    }
}

foreach ($Tool in @('git', 'flutter', 'rustup', 'cargo')) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Missing $Tool. Follow desktop\README-Windows.txt before building."
    }
}
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'This first desktop package targets Windows x64, not ARM64 or 32-bit Windows.'
}
$FlutterInfo = (& flutter --version --machine | Out-String | ConvertFrom-Json)
if ($FlutterInfo.frameworkVersion -ne '3.47.5') {
    throw 'Use Flutter 3.47.5 stable, the same SDK as the Android source in this package.'
}
$VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $VsWhere)) {
    throw 'Install Visual Studio 2022 Build Tools with Desktop development with C++ and the Windows 11 SDK.'
}
$VsPath = & $VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $VsPath) { throw 'The Visual Studio C++ x64 compiler workload is missing.' }
$DevShell = Join-Path $VsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
Import-Module $DevShell
Enter-VsDevShell -VsInstallPath $VsPath -SkipAutomaticLocation -DevCmdArguments '-arch=amd64 -host_arch=amd64'

# Only this PowerShell process gets these build settings. No Git remotes,
# system security settings, wallet files or global Git settings are changed.
$env:RUSTUP_TOOLCHAIN = '1.97.1'
$env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true'
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'core.longpaths'
$env:GIT_CONFIG_VALUE_0 = 'true'
$env:CARGO_BUILD_JOBS = '2'
Push-Location $ProjectRoot
try {
    # Format conversion only: reuse Android's Kaspire icon exactly.
    Add-Type -AssemblyName System.Drawing
    $IconImage = [Drawing.Image]::FromFile((Join-Path $AppRoot 'assets\branding\kaspire_app_icon_v4.png'))
    $IconBitmap = New-Object Drawing.Bitmap 256, 256
    $IconGraphics = [Drawing.Graphics]::FromImage($IconBitmap)
    $IconGraphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $IconGraphics.DrawImage($IconImage, 0, 0, 256, 256)
    $IconBytes = New-Object IO.MemoryStream
    $IconBitmap.Save($IconBytes, [Drawing.Imaging.ImageFormat]::Png)
    $IconStream = [IO.File]::Create((Join-Path $AppRoot 'windows\runner\resources\app_icon.ico'))
    $IconWriter = New-Object IO.BinaryWriter $IconStream
    try {
        $IconWriter.Write([uint16]0); $IconWriter.Write([uint16]1); $IconWriter.Write([uint16]1)
        $IconWriter.Write([byte]0); $IconWriter.Write([byte]0); $IconWriter.Write([byte]0); $IconWriter.Write([byte]0)
        $IconWriter.Write([uint16]1); $IconWriter.Write([uint16]32)
        $IconWriter.Write([uint32]$IconBytes.Length); $IconWriter.Write([uint32]22)
        $IconWriter.Write($IconBytes.ToArray())
    } finally {
        $IconWriter.Dispose(); $IconStream.Dispose(); $IconBytes.Dispose()
        $IconGraphics.Dispose(); $IconBitmap.Dispose(); $IconImage.Dispose()
    }
    Invoke-BuildCommand 'rustup' @('toolchain', 'install', '1.97.1', '--profile', 'minimal')
    Invoke-BuildCommand 'rustup' @('target', 'add', 'x86_64-pc-windows-msvc')
    if (-not $SkipChecks) {
        Invoke-BuildCommand 'cargo' @('test', '--locked', '--release', '--target', 'x86_64-pc-windows-msvc', '-p', 'kaspa_secure_core', '--features', 'desktop')
    }
    Invoke-BuildCommand 'cargo' @('build', '--locked', '--release', '-p', 'kaspa_secure_core', '--features', 'desktop', '--target', 'x86_64-pc-windows-msvc')
    Push-Location $AppRoot
    try {
        Invoke-BuildCommand 'flutter' @('pub', 'get')
        if (-not $SkipChecks) {
            Invoke-BuildCommand 'flutter' @('analyze')
            Invoke-BuildCommand 'flutter' @('test', 'test/desktop_test.dart')
        }
        Invoke-BuildCommand 'flutter' @('build', 'windows', '--release', "--build-name=$DesktopVersion", "--build-number=$DesktopBuild")
    } finally { Pop-Location }
    $Release = Join-Path $AppRoot 'build\windows\x64\runner\Release'
    $CoreDll = Join-Path $ProjectRoot 'target\x86_64-pc-windows-msvc\release\kaspa_secure_core.dll'
    if (-not (Test-Path (Join-Path $Release 'kaspire.exe'))) { throw 'Flutter did not produce kaspire.exe.' }
    if (-not (Test-Path $CoreDll)) { throw 'The native Rust signing DLL is missing.' }
    Copy-Item $CoreDll (Join-Path $Release 'kaspa_secure_core.dll') -Force
    $Output = Join-Path $ProjectRoot "dist\Kaspire-Windows-$DesktopVersion"
    if (Test-Path $Output) {
        $Output = Join-Path $ProjectRoot ("dist\Kaspire-Windows-$DesktopVersion-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    New-Item -ItemType Directory -Path $Output -Force | Out-Null
    Copy-Item (Join-Path $Release '*') $Output -Recurse
    Copy-Item (Join-Path $PSScriptRoot 'README-Windows.txt') (Join-Path $Output 'README.txt')
    Get-ChildItem $Output -File -Recurse | Get-FileHash -Algorithm SHA256 |
        Format-Table -AutoSize | Out-String -Width 300 |
        Set-Content (Join-Path $Output 'SHA256SUMS.txt') -Encoding UTF8
    Write-Host "`nBuild completed: $Output\kaspire.exe" -ForegroundColor Green
    Write-Host 'Keep the entire folder together; the EXE alone is not the wallet.'
    Write-Host 'Wallet data and recovery backups are stored separately from the application bundle.'
} finally { Pop-Location }
