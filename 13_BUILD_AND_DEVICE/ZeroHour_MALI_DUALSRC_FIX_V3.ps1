# ZeroHour_MALI_DUALSRC_FIX_V3.ps1
# Purpose: Safely relax only the Android dualSrcBlend adapter-enumeration gate in the
# already-built fbraz3/Molotov-oriented DXVK tree, rebuild DXVK incrementally, stage
# the new D3D8/D3D9 ELF libraries, package/install the APK without rebuilding
# libmain.so, launch the game, and capture the next proven runtime blocker.
#
# IMPORTANT:
# - Windows PowerShell 5.1 compatible.
# - Does NOT clone DXVK.
# - Does NOT rebuild libmain.so.
# - Does NOT copy or modify original GameData.
# - Fails closed if expected source/build/project markers are missing.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Repo = 'C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN'
$AndroidDir = Join-Path $Repo 'android'
$DxvkSrc = Join-Path $Repo 'tools\mali-dxvk\actual-dxvk-source'
$DxvkBuild = Join-Path $Repo 'tools\mali-dxvk\build-android-real'
$DeviceInfo = Join-Path $DxvkSrc 'src\dxvk\dxvk_device_info.cpp'
$SdlWsi = Join-Path $DxvkSrc 'src\wsi\sdl3\wsi_platform_sdl3.cpp'
$D3D8Out = Join-Path $DxvkBuild 'src\d3d8\libdxvk_d3d8.so'
$D3D9Out = Join-Path $DxvkBuild 'src\d3d9\libdxvk_d3d9.so'
$JniDir = Join-Path $AndroidDir 'app\src\main\jniLibs\arm64-v8a'
$D3D8Stage = Join-Path $JniDir 'libdxvk_d3d8.so'
$D3D9Stage = Join-Path $JniDir 'libdxvk_d3d9.so'
$GradleApp = Join-Path $AndroidDir 'app\build.gradle'
$GradleAppKts = Join-Path $AndroidDir 'app\build.gradle.kts'
$Apk = Join-Path $AndroidDir 'app\build\outputs\apk\debug\app-debug.apk'
$Sdk = 'C:\Users\DELL\AppData\Local\Android\Sdk'
$Adb = Join-Path $Sdk 'platform-tools\adb.exe'
$JavaHome = 'C:\Program Files\Android\Android Studio\jbr'
$Log = 'C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt'
$Package = 'me.generalsx.zh'
$Activity = 'me.generalsx.zh/.GameActivity'

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

Step 'Environment checks'
Assert-Path $Repo 'Current Android repo'
Assert-Path $AndroidDir 'Android project'
Assert-Path $DxvkSrc 'DXVK source'
Assert-Path $DxvkBuild 'DXVK build directory'
Assert-Path $DeviceInfo 'DXVK feature source'
Assert-Path $SdlWsi 'SDL3 WSI source'
Assert-Path $Adb 'adb'
Assert-Path $JavaHome 'Android Studio JBR'

$env:JAVA_HOME = $JavaHome
$env:ANDROID_SDK_ROOT = $Sdk
$env:ANDROID_HOME = $Sdk
$env:Path = (Join-Path $JavaHome 'bin') + ';' + (Join-Path $Sdk 'platform-tools') + ';' + $env:Path

Step 'Verify proven SDL3 Android loader patch is still present'
$sdlText = [System.IO.File]::ReadAllText($SdlWsi)
if ($sdlText -notmatch 'ZH_ANDROID_SDL3_DLOPEN_OK' -and $sdlText -notmatch 'dlopen\s*\(\s*"libSDL3\.so"') {
    Fail 'Proven Android SDL3 direct-dlopen patch marker was not found. Refusing to rebuild a regressed DXVK tree.'
}
Write-Host 'SDL3 Android loader patch detected.'

Step 'Patch only Android dualSrcBlend requirement'
$source = [System.IO.File]::ReadAllText($DeviceInfo)
$marker = 'ZEROHOUR_ANDROID_MALI_DUALSRC_OPTIONAL'
$requiredLine = 'ENABLE_FEATURE(core.features, dualSrcBlend, true),'

if ($source.Contains($marker)) {
    Write-Host 'dualSrcBlend Android patch already present; leaving source unchanged.'
} else {
    $count = ([regex]::Matches($source, [regex]::Escape($requiredLine))).Count
    if ($count -ne 1) {
        Fail "Expected exact dualSrcBlend requirement once, found $count. Source layout changed; refusing ambiguous patch."
    }

    $replacement = @"
#if defined(__ANDROID__)
      // ZEROHOUR_ANDROID_MALI_DUALSRC_OPTIONAL
      ENABLE_FEATURE(core.features, dualSrcBlend, false),
#else
      ENABLE_FEATURE(core.features, dualSrcBlend, true),
#endif
"@

    $source = $source.Replace($requiredLine, $replacement.TrimEnd("`r","`n"))
    [System.IO.File]::WriteAllText($DeviceInfo, $source, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'Applied Android-only dualSrcBlend requirement relaxation.'
}

$verify = [System.IO.File]::ReadAllText($DeviceInfo)
if ($verify -notmatch 'ZEROHOUR_ANDROID_MALI_DUALSRC_OPTIONAL') { Fail 'Patch verification failed.' }

Step 'Incremental DXVK rebuild'
$ninja = Get-Command ninja.exe -ErrorAction SilentlyContinue
if (-not $ninja) { $ninja = Get-Command ninja -ErrorAction SilentlyContinue }
if (-not $ninja) { Fail 'ninja was not found in PATH.' }
Invoke-Native $ninja.Source @('-C', $DxvkBuild) 'DXVK Ninja build'

Step 'Verify rebuilt DXVK ELF outputs'
Assert-Elf $D3D8Out
Assert-Elf $D3D9Out

Step 'Stage D3D8/D3D9 libraries'
if (-not (Test-Path -LiteralPath $JniDir)) { New-Item -ItemType Directory -Force -Path $JniDir | Out-Null }
Copy-Item -LiteralPath $D3D8Out -Destination $D3D8Stage -Force
Copy-Item -LiteralPath $D3D9Out -Destination $D3D9Stage -Force
Assert-Elf $D3D8Stage
Assert-Elf $D3D9Stage

Step 'Verify package-only Gradle path and native packaging setting'
$gradleFile = $null
if (Test-Path -LiteralPath $GradleApp) { $gradleFile = $GradleApp }
elseif (Test-Path -LiteralPath $GradleAppKts) { $gradleFile = $GradleAppKts }
else { Fail 'app/build.gradle(.kts) not found.' }
$gradleText = [System.IO.File]::ReadAllText($gradleFile)
if (-not $gradleText.Contains("project.hasProperty('SAGE_SKIP_NATIVE_BUILD')")) {
    Fail "SAGE_SKIP_NATIVE_BUILD guard was not found in $gradleFile. Refusing a package step that may rebuild libmain.so."
}
if ($gradleText -notmatch 'useLegacyPackaging\s*(=|\s)\s*false') {
    Fail "useLegacyPackaging false was not found in $gradleFile. Refusing to risk native ELF packaging regression."
}
Write-Host 'Package-only guard and useLegacyPackaging false detected.'

Step 'Package APK without native engine rebuild'
Push-Location $AndroidDir
try {
    $gradlew = Join-Path $AndroidDir 'gradlew.bat'
    Assert-Path $gradlew 'Gradle wrapper'
    Invoke-Native $gradlew @('-PSAGE_SKIP_NATIVE_BUILD=true', ':app:assembleDebug', '--stacktrace') 'Gradle package-only APK build'
} finally {
    Pop-Location
}
Assert-Path $Apk 'Debug APK'

Step 'Verify APK contains uncompressed ELF JNI libraries'
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

Step 'Install APK without touching GameData'
Invoke-Native $Adb @('install','-r','-d',$Apk) 'adb install'

Step 'Capture clean runtime log and launch'
& $Adb logcat -c | Out-Null
Invoke-Native $Adb @('shell','am','force-stop',$Package) 'force-stop'
Invoke-Native $Adb @('shell','am','start','-n',$Activity) 'activity launch'
Start-Sleep -Seconds 12

$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $Adb logcat -d -v time 2>&1 | Out-File -LiteralPath $Log -Encoding utf8
$logCode = $LASTEXITCODE
$ErrorActionPreference = $old
if ($logCode -ne 0) { Fail "adb logcat capture failed with exit code $logCode" }

Step 'Runtime gate summary'
$logText = Get-Content -LiteralPath $Log -Raw
$patterns = @(
    "Skipping: Device does not support required feature '[^']+'",
    'Required Vulkan extension [A-Za-z0-9_]+' ,
    'DxvkAdapter: Failed to create device',
    'DXVK: No adapters found',
    'FATAL EXCEPTION',
    'Fatal signal [0-9]+',
    'Scudo ERROR',
    'bad ELF magic',
    'ZH_ANDROID_SDL3_DLOPEN_OK'
)

$hits = New-Object System.Collections.Generic.List[string]
foreach ($pattern in $patterns) {
    foreach ($m in [regex]::Matches($logText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        if (-not $hits.Contains($m.Value)) { $hits.Add($m.Value) }
    }
}

if ($hits.Count -eq 0) {
    Write-Host 'No known blocker pattern matched. Inspect the runtime log for the first renderer/menu outcome.' -ForegroundColor Yellow
} else {
    Write-Host 'Relevant runtime markers:'
    $hits | ForEach-Object { Write-Host ('  ' + $_) }
}

Write-Host ''
Write-Host ('RUNTIME LOG: ' + $Log) -ForegroundColor Green
Write-Host 'Do not treat this script finishing as proof the game is working; the runtime log is the authority.' -ForegroundColor Yellow
