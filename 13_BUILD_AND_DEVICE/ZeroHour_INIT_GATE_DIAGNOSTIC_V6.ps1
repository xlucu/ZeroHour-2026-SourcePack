# ZeroHour_INIT_GATE_DIAGNOSTIC_V6.ps1
# Purpose: Diagnose the proven EXIT_SELF(status=1) that occurs immediately after
# GE::init: ThingFactory done. Adds Android-only log markers around the next real
# GameEngine subsystems and the init exception handlers, rebuilds libmain/APK,
# installs, launches, and captures one authoritative runtime log.
#
# This script does NOT alter Gameplay, does NOT touch GameData, and does NOT
# rebuild or replace the already-staged DXVK D3D8/D3D9 libraries.
# Windows PowerShell 5.1 compatible.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Repo = 'C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN'
$AndroidDir = Join-Path $Repo 'android'
$GameEngineCpp = Join-Path $Repo 'Generals\Code\GameEngine\Source\Common\GameEngine.cpp'
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
$Log = 'C:\Users\DELL\Desktop\ZeroHour_INIT_GATE_LOG.txt'
$Package = 'me.generalsx.zh'
$Activity = 'me.generalsx.zh/.GameActivity'
$RequiredGradleVersion = '8.7'
$Marker = 'ZEROHOUR_ANDROID_INIT_GATE_V6'

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
        if ($code -eq 0 -and $verText -match 'Gradle\s+8\.7(\D|$)') { return $cmd.Source }
    }

    $gradleHome = Join-Path $env:USERPROFILE '.gradle'
    if (Test-Path -LiteralPath $gradleHome) {
        $cached = Get-ChildItem -LiteralPath $gradleHome -Recurse -Filter 'gradle.bat' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'gradle-8\.7\\bin\\gradle\.bat$' } |
            Select-Object -First 1
        if ($cached) { return $cached.FullName }
    }

    $toolsRoot = Join-Path $Repo 'tools\gradle'
    $distRoot = Join-Path $toolsRoot 'gradle-8.7'
    $gradleBat = Join-Path $distRoot 'bin\gradle.bat'
    if (Test-Path -LiteralPath $gradleBat) { return $gradleBat }

    if (-not (Test-Path -LiteralPath $toolsRoot)) { New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null }
    $zipPath = Join-Path $toolsRoot 'gradle-8.7-bin.zip'
    $url = 'https://services.gradle.org/distributions/gradle-8.7-bin.zip'
    Write-Host ('Downloading pinned Gradle 8.7: ' + $url)
    Invoke-WebRequest -UseBasicParsing $url -OutFile $zipPath
    if (Test-Path -LiteralPath $distRoot) { Remove-Item -LiteralPath $distRoot -Recurse -Force }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $toolsRoot -Force
    if (-not (Test-Path -LiteralPath $gradleBat)) { Fail 'Pinned Gradle 8.7 extraction did not produce gradle.bat.' }
    return $gradleBat
}

function Replace-Once([string]$Text, [string]$Needle, [string]$Replacement, [string]$Label) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Needle))).Count
    if ($count -ne 1) { Fail "$Label anchor expected once, found $count. Refusing ambiguous source patch." }
    return $Text.Replace($Needle, $Replacement)
}

Step 'Verify proven starting state'
Assert-Path $Repo 'Current Android repo'
Assert-Path $AndroidDir 'Android project'
Assert-Path $GameEngineCpp 'GameEngine.cpp'
Assert-Path $GradleProps 'Gradle wrapper properties'
Assert-Path $GradleApp 'Android app Gradle file'
Assert-Path $Adb 'adb'
Assert-Path $JavaHome 'Android Studio JBR'
Assert-Elf $D3D8Stage
Assert-Elf $D3D9Stage
Assert-Elf $SDL3Stage

$props = [System.IO.File]::ReadAllText($GradleProps)
if ($props -notmatch 'gradle-8\.7-bin\.zip') { Fail 'Project no longer pins Gradle 8.7.' }
$gradleText = [System.IO.File]::ReadAllText($GradleApp)
if ($gradleText -notmatch 'useLegacyPackaging\s*(=|\s)\s*false') { Fail 'useLegacyPackaging false is missing.' }

$env:JAVA_HOME = $JavaHome
$env:ANDROID_SDK_ROOT = $Sdk
$env:ANDROID_HOME = $Sdk
$env:Path = (Join-Path $JavaHome 'bin') + ';' + (Join-Path $Sdk 'platform-tools') + ';' + $env:Path

Step 'Add Android-only init gate diagnostics'
$src = [System.IO.File]::ReadAllText($GameEngineCpp)

if ($src.Contains($Marker)) {
    Write-Host 'V6 source diagnostics already present; source left unchanged.'
} else {
    $preRts = '#include "PreRTS.h"\t// This must go first in EVERY cpp file in the GameEngine'
    if (-not $src.Contains($preRts)) {
        # Some local trees use real tab instead of literal \t in this comment. Fall back to the include only.
        $preRts = '#include "PreRTS.h"'
    }
    $diagHeader = @"
$preRts

#if defined(__ANDROID__)
#include <android/log.h>
#define ZH_INIT_GATE_LOG(...) __android_log_print(ANDROID_LOG_INFO, "ZH_InitGate", __VA_ARGS__)
#else
#define ZH_INIT_GATE_LOG(...) ((void)0)
#endif
// $Marker
"@
    $src = Replace-Once $src $preRts $diagHeader.TrimEnd("`r","`n") 'Android log helper'

    $gates = @(
        @{ Name='UpgradeCenter'; Line='\t\tinitSubsystem(TheUpgradeCenter,"TheUpgradeCenter", MSGNEW("GameEngineSubsystem") UpgradeCenter, &xferCRC, "Data\\\\INI\\\\Default\\\\Upgrade", "Data\\\\INI\\\\Upgrade");' },
        @{ Name='GameClient'; Line='\t\tinitSubsystem(TheGameClient,"TheGameClient", createGameClient(), nullptr);' },
        @{ Name='AI'; Line='\t\tinitSubsystem(TheAI,"TheAI", MSGNEW("GameEngineSubsystem") AI(), &xferCRC,  "Data\\\\INI\\\\Default\\\\AIData", "Data\\\\INI\\\\AIData");' },
        @{ Name='GameLogic'; Line='\t\tinitSubsystem(TheGameLogic,"TheGameLogic", createGameLogic(), nullptr);' },
        @{ Name='TeamFactory'; Line='\t\tinitSubsystem(TheTeamFactory,"TheTeamFactory", MSGNEW("GameEngineSubsystem") TeamFactory(), nullptr);' },
        @{ Name='CrateSystem'; Line='\t\tinitSubsystem(TheCrateSystem,"TheCrateSystem", MSGNEW("GameEngineSubsystem") CrateSystem(), &xferCRC, "Data\\\\INI\\\\Default\\\\Crate", "Data\\\\INI\\\\Crate");' },
        @{ Name='PlayerList'; Line='\t\tinitSubsystem(ThePlayerList,"ThePlayerList", MSGNEW("GameEngineSubsystem") PlayerList(), nullptr);' },
        @{ Name='Recorder'; Line='\t\tinitSubsystem(TheRecorder,"TheRecorder", createRecorder(), nullptr);' },
        @{ Name='Radar'; Line='\t\tinitSubsystem(TheRadar,"TheRadar", createRadar(TheGlobalData->m_headless), nullptr);' },
        @{ Name='VictoryConditions'; Line='\t\tinitSubsystem(TheVictoryConditions,"TheVictoryConditions", createVictoryConditions(), nullptr);' }
    )

    foreach ($g in $gates) {
        # Convert escaped tab/backslashes in table literal into the exact C++ source form.
        $line = $g.Line.Replace('\t', "`t").Replace('\\\\','\\')
        $replacement = "`t`tZH_INIT_GATE_LOG(\"BEGIN $($g.Name)\");`r`n" + $line + "`r`n`t`tZH_INIT_GATE_LOG(\"OK $($g.Name)\");"
        $src = Replace-Once $src $line $replacement $g.Name
    }

    $iniCatch = @"
\tcatch (INIException e)
\t{
\t\tif (e.mFailureMessage)
\t\t\tRELEASE_CRASH((e.mFailureMessage));
\t\telse
\t\t\tRELEASE_CRASH(("Uncaught Exception during initialization."));

\t}
"@.Replace('\t',"`t")
    $iniCatchReplacement = @"
\tcatch (INIException e)
\t{
\t\tZH_INIT_GATE_LOG("CATCH INIException message=%s", e.mFailureMessage ? e.mFailureMessage : "(null)");
\t\tif (e.mFailureMessage)
\t\t\tRELEASE_CRASH((e.mFailureMessage));
\t\telse
\t\t\tRELEASE_CRASH(("Uncaught Exception during initialization."));

\t}
"@.Replace('\t',"`t")
    $src = Replace-Once $src $iniCatch $iniCatchReplacement 'INIException catch'

    $genericCatch = @"
\tcatch (...)
\t{
\t\tRELEASE_CRASH(("Uncaught Exception during initialization."));
\t}
"@.Replace('\t',"`t")
    $genericCatchReplacement = @"
\tcatch (...)
\t{
\t\tZH_INIT_GATE_LOG("CATCH unknown exception during GameEngine::init");
\t\tRELEASE_CRASH(("Uncaught Exception during initialization."));
\t}
"@.Replace('\t',"`t")
    # GameEngine.cpp has another catch(...) in update(); patch only the exact init catch block above.
    $src = Replace-Once $src $genericCatch $genericCatchReplacement 'init generic catch'

    [System.IO.File]::WriteAllText($GameEngineCpp, $src, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'Android-only init gate instrumentation applied.'
}

$check = [System.IO.File]::ReadAllText($GameEngineCpp)
if (-not $check.Contains($Marker)) { Fail 'Diagnostic patch verification failed.' }
if (-not $check.Contains('ZH_INIT_GATE_LOG("BEGIN UpgradeCenter")')) { Fail 'UpgradeCenter begin marker missing after patch.' }
if (-not $check.Contains('ZH_INIT_GATE_LOG("CATCH INIException')) { Fail 'INIException marker missing after patch.' }

Step 'Resolve pinned Gradle 8.7'
$Gradle = Find-Gradle87
Write-Host ('Gradle: ' + $Gradle) -ForegroundColor Green
Invoke-Native $Gradle @('--version') 'Gradle version check'

Step 'Rebuild native engine and APK'
Push-Location $AndroidDir
try {
    # Intentionally do NOT pass SAGE_SKIP_NATIVE_BUILD: this diagnostic source change
    # must be compiled into libmain.so. DXVK remains pre-staged in jniLibs.
    Invoke-Native $Gradle @(':app:assembleDebug','--stacktrace','--no-daemon') 'Gradle native/APK build'
} finally {
    Pop-Location
}
Assert-Path $Apk 'Debug APK'

Step 'Verify APK critical native libraries'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($Apk)
try {
    foreach ($name in @('lib/arm64-v8a/libmain.so','lib/arm64-v8a/libdxvk_d3d8.so','lib/arm64-v8a/libdxvk_d3d9.so','lib/arm64-v8a/libSDL3.so')) {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $name } | Select-Object -First 1
        if (-not $entry) { Fail "APK entry missing: $name" }
        $stream = $entry.Open()
        try {
            $b = New-Object byte[] 4
            [void]$stream.Read($b,0,4)
            $magic = (($b | ForEach-Object { $_.ToString('X2') }) -join '')
            if ($magic -ne '7F454C46') { Fail "APK entry is not ELF: $name (magic=$magic)" }
        } finally { $stream.Dispose() }
        if ($entry.CompressedLength -ne $entry.Length) { Fail "APK JNI library is compressed: $name" }
        Write-Host "APK ELF/STORED OK: $name"
    }
} finally { $zip.Dispose() }

Step 'Verify exactly one authorized Android device'
$deviceLines = & $Adb devices
$devices = @($deviceLines | Select-String "`tdevice$" | ForEach-Object { ($_.Line -split "`t")[0].Trim() })
if ($devices.Count -ne 1) { Fail "Exactly one authorized Android device is required. Found=$($devices.Count)" }
Write-Host "Device: $($devices[0])"

Step 'Install and launch without touching GameData'
Invoke-Native $Adb @('install','-r','-d',$Apk) 'adb install'
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

Step 'First proven init gate result'
$logText = Get-Content -LiteralPath $Log -Raw
$gateLines = Get-Content -LiteralPath $Log | Where-Object { $_ -match 'ZH_InitGate|GeneralsX.*GE::init|EXIT_SELF|Process me\.generalsx\.zh.*died|FATAL EXCEPTION|Fatal signal' }
if ($gateLines.Count -gt 0) {
    $gateLines | Select-Object -Last 80 | ForEach-Object { Write-Host $_ }
} else {
    Write-Host 'No init-gate markers found; inspect full log.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host ('RUNTIME LOG: ' + $Log) -ForegroundColor Green
Write-Host 'The last BEGIN/OK/CATCH marker is the authority for the next fix.' -ForegroundColor Yellow
