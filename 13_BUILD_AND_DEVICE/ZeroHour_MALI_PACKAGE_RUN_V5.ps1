# ZeroHour_MALI_PACKAGE_RUN_V5.ps1
# Continues from the proven V4 state: DXVK dualSrcBlend patch already present,
# incremental DXVK build succeeded, and rebuilt D3D8/D3D9 ELF files are staged.
# This script does NOT rebuild DXVK or libmain.so and does NOT touch GameData.
# It resolves the missing Gradle launcher, packages, installs, launches, and logs.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Repo = 'C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN'
$AndroidDir = Join-Path $Repo 'android'
$DxvkSrc = Join-Path $Repo 'tools\mali-dxvk\actual-dxvk-source'
$DeviceInfo = Join-Path $DxvkSrc 'src\dxvk\dxvk_device_info.cpp'
$JniDir = Join-Path $AndroidDir 'app\src\main\jniLibs\arm64-v8a'
$D3D8Stage = Join-Path $JniDir 'libdxvk_d3d8.so'
$D3D9Stage = Join-Path $JniDir 'libdxvk_d3d9.so'
$SDL3Stage = Join-Path $JniDir 'libSDL3.so'
$GradleProps = Join-Path $AndroidDir 'gradle\wrapper\gradle-wrapper.properties'
$GradleApp = Join-Path $AndroidDir 'app\build.gradle'
$Apk = Join-Path $AndroidDir 'app\build\outputs\apk\debug\app-debug.apk'
$Sdk = 'C:\Users\DELL\AppData\Local\Android\Sdk'
$Adb = Join-Path $Sdk 'platform-tools\adb.exe'
$JavaHome = 'C:\Program Files\Android\Android Studio\jbr'
$Log = 'C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt'
$Package = 'me.generalsx.zh'
$Activity = 'me.generalsx.zh/.GameActivity'
$RequiredGradleVersion = '8.7'

function Step([string]$Text) {
    Write-Host ''
    Write-Host ('=== ' + $Text + ' ===') -ForegroundColor Cyan
}

function Fail([string]$Text) {
    Write-Host ('FAILED: ' + $Text) -ForegroundColor Red
    throw $Text
}

function Assert-Path([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { Fail "$Label not found: $Path" }
}

function Get-Hex4([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 4) { return '' }
    return (($bytes[0..3] | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Assert-Elf([string]$Path) {
    Assert-Path $Path 'ELF candidate'
    $magic = Get-Hex4 $Path
    if ($magic -ne '7F454C46') { Fail "Not ELF: $Path (magic=$magic)" }
    Write-Host "ELF OK: $Path"
}

function Invoke-Native([string]$Exe, [string[]]$NativeArgs, [string]$Label) {
    Write-Host ("> " + $Exe + ' ' + ($NativeArgs -join ' '))
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Exe @NativeArgs
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0) { Fail "$Label failed with exit code $code" }
}

function Find-Gradle87 {
    $cmd = Get-Command gradle.bat -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command gradle -ErrorAction SilentlyContinue }
    if ($cmd) {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $verText = (& $cmd.Source --version 2>&1 | Out-String)
        $code = $LASTEXITCODE
        $ErrorActionPreference = $old
        if ($code -eq 0 -and $verText -match 'Gradle\s+8\.7(\D|$)') {
            return $cmd.Source
        }
    }

    $gradleHome = Join-Path $env:USERPROFILE '.gradle'
    if (Test-Path -LiteralPath $gradleHome) {
        $candidate = Get-ChildItem -LiteralPath $gradleHome -Recurse -Filter 'gradle.bat' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\gradle-8\.7\\bin\\gradle\.bat$' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }

    return $null
}

Step 'Verify proven staged DXVK state'
Assert-Path $Repo 'Current Android repo'
Assert-Path $AndroidDir 'Android project'
Assert-Path $DeviceInfo 'DXVK device feature source'
Assert-Path $GradleProps 'Gradle wrapper properties'
Assert-Path $GradleApp 'App Gradle file'
Assert-Path $Adb 'adb'
Assert-Path $JavaHome 'Android Studio JBR'
Assert-Elf $D3D8Stage
Assert-Elf $D3D9Stage
Assert-Elf $SDL3Stage

$deviceInfoText = [System.IO.File]::ReadAllText($DeviceInfo)
if ($deviceInfoText -notmatch 'ZEROHOUR_ANDROID_MALI_DUALSRC_OPTIONAL') {
    Fail 'Android dualSrcBlend patch marker is missing; refusing to package an unverified DXVK state.'
}
Write-Host 'dualSrcBlend Android patch marker detected.'

$propsText = [System.IO.File]::ReadAllText($GradleProps)
if ($propsText -notmatch 'gradle-8\.7-bin\.zip') {
    Fail 'Project no longer pins Gradle 8.7; refusing to guess a Gradle version.'
}
$gradleText = [System.IO.File]::ReadAllText($GradleApp)
if (-not $gradleText.Contains("project.hasProperty('SAGE_SKIP_NATIVE_BUILD')")) {
    Fail 'SAGE_SKIP_NATIVE_BUILD guard is missing; refusing to risk rebuilding libmain.so.'
}
if ($gradleText -notmatch 'useLegacyPackaging\s*(=|\s)\s*false') {
    Fail 'useLegacyPackaging false is missing; refusing possible ELF packaging regression.'
}

$env:JAVA_HOME = $JavaHome
$env:ANDROID_SDK_ROOT = $Sdk
$env:ANDROID_HOME = $Sdk
$env:Path = (Join-Path $JavaHome 'bin') + ';' + (Join-Path $Sdk 'platform-tools') + ';' + $env:Path

Step 'Resolve pinned Gradle 8.7 launcher'
$GradleExe = Find-Gradle87
if (-not $GradleExe) {
    Write-Host 'Gradle 8.7 is not cached. Downloading the exact project-pinned distribution...' -ForegroundColor Yellow
    $toolRoot = Join-Path $env:LOCALAPPDATA 'ZeroHour2026\tools'
    $zipPath = Join-Path $toolRoot 'gradle-8.7-bin.zip'
    $extractRoot = Join-Path $toolRoot 'gradle-8.7-dist'
    $expectedExe = Join-Path $extractRoot 'gradle-8.7\bin\gradle.bat'
    if (-not (Test-Path -LiteralPath $toolRoot)) { New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null }

    if (-not (Test-Path -LiteralPath $expectedExe)) {
        if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
        if (-not (Test-Path -LiteralPath $zipPath)) {
            Invoke-WebRequest -UseBasicParsing 'https://services.gradle.org/distributions/gradle-8.7-bin.zip' -OutFile $zipPath
        }
        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
    }
    Assert-Path $expectedExe 'Downloaded Gradle 8.7 launcher'
    $GradleExe = $expectedExe
}
Write-Host ('Gradle launcher: ' + $GradleExe) -ForegroundColor Green

$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$versionOutput = (& $GradleExe --version 2>&1 | Out-String)
$versionCode = $LASTEXITCODE
$ErrorActionPreference = $old
Write-Host $versionOutput.Trim()
if ($versionCode -ne 0 -or $versionOutput -notmatch 'Gradle\s+8\.7(\D|$)') {
    Fail 'Resolved Gradle launcher is not Gradle 8.7.'
}

Step 'Package APK only; do not rebuild native engine'
Push-Location $AndroidDir
try {
    Invoke-Native $GradleExe @('-PSAGE_SKIP_NATIVE_BUILD=true', ':app:assembleDebug', '--stacktrace') 'Gradle package-only APK build'
} finally {
    Pop-Location
}
Assert-Path $Apk 'Debug APK'

Step 'Verify APK JNI payload'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($Apk)
try {
    foreach ($name in @('lib/arm64-v8a/libdxvk_d3d8.so','lib/arm64-v8a/libdxvk_d3d9.so','lib/arm64-v8a/libSDL3.so')) {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $name } | Select-Object -First 1
        if (-not $entry) { Fail "APK entry missing: $name" }
        $stream = $entry.Open()
        try {
            $b = New-Object byte[] 4
            [void]$stream.Read($b,0,4)
            $magic = (($b | ForEach-Object { $_.ToString('X2') }) -join '')
            if ($magic -ne '7F454C46') { Fail "APK entry is not ELF: $name (magic=$magic)" }
        } finally { $stream.Dispose() }
        if ($entry.CompressedLength -ne $entry.Length) {
            Fail "APK JNI library is compressed: $name (compressed=$($entry.CompressedLength), raw=$($entry.Length))"
        }
        Write-Host "APK ELF/STORED OK: $name"
    }
} finally {
    $zip.Dispose()
}

Step 'Verify exactly one authorized Android device'
$deviceLines = & $Adb devices
$devices = @($deviceLines | Select-String "`tdevice$" | ForEach-Object { ($_.Line -split "`t")[0].Trim() })
if ($devices.Count -ne 1) { Fail "Exactly one authorized Android device is required. Found=$($devices.Count)" }
Write-Host "Device: $($devices[0])"

Step 'Install without touching GameData'
Invoke-Native $Adb @('install','-r','-d',$Apk) 'adb install'

Step 'Launch and capture runtime log'
& $Adb logcat -c | Out-Null
Invoke-Native $Adb @('shell','am','force-stop',$Package) 'force-stop'
Invoke-Native $Adb @('shell','am','start','-n',$Activity) 'activity launch'
Start-Sleep -Seconds 15

$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $Adb logcat -d -v time 2>&1 | Out-File -LiteralPath $Log -Encoding utf8
$logCode = $LASTEXITCODE
$ErrorActionPreference = $old
if ($logCode -ne 0) { Fail "adb logcat capture failed with exit code $logCode" }

Step 'First runtime blocker summary'
$logText = Get-Content -LiteralPath $Log -Raw
$patterns = @(
    "Skipping: Device does not support required feature '[^']+'",
    'Required Vulkan extension [A-Za-z0-9_]+' ,
    'DxvkAdapter: Failed to create device',
    'DXVK: No adapters found',
    'FATAL EXCEPTION',
    'Fatal signal [0-9]+',
    'Scudo ERROR[^\r\n]*',
    'bad ELF magic[^\r\n]*',
    'ZH_ANDROID_SDL3_DLOPEN_OK'
)
$hits = New-Object System.Collections.Generic.List[string]
foreach ($pattern in $patterns) {
    foreach ($m in [regex]::Matches($logText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        if (-not $hits.Contains($m.Value)) { $hits.Add($m.Value) }
    }
}
if ($hits.Count -eq 0) {
    Write-Host 'No known blocker pattern matched. Runtime log must be inspected for the first new outcome.' -ForegroundColor Yellow
} else {
    Write-Host 'Relevant runtime markers:'
    $hits | ForEach-Object { Write-Host ('  ' + $_) }
}

Write-Host ''
Write-Host ('RUNTIME LOG: ' + $Log) -ForegroundColor Green
Write-Host 'Package/install/launch completed. The runtime log, not this message, determines game success.' -ForegroundColor Yellow
