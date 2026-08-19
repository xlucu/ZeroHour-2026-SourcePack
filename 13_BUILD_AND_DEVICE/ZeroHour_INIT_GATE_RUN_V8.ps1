# ZeroHour_INIT_GATE_RUN_V8.ps1
# Corrects V7's source-root mistake: Zero Hour builds GeneralsMD/z_generals, not
# Generals/g_generals. Instruments the actual Zero Hour GameEngine.cpp, performs
# a real native rebuild, PROVES the V8 marker is inside APK libmain.so, installs,
# runs, and captures the first exact post-ThingFactory gate.
# Windows PowerShell 5.1 compatible.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Repo = 'C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN'
$AndroidDir = Join-Path $Repo 'android'
$ZeroHourGameEngine = Join-Path $Repo 'GeneralsMD\Code\GameEngine\Source\Common\GameEngine.cpp'
$WrongGeneralsGameEngine = Join-Path $Repo 'Generals\Code\GameEngine\Source\Common\GameEngine.cpp'
$Sdk = 'C:\Users\DELL\AppData\Local\Android\Sdk'
$Ndk = Join-Path $Sdk 'ndk\27.1.12297006'
$Adb = Join-Path $Sdk 'platform-tools\adb.exe'
$LlvmStrings = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strings.exe'
$JavaHome = 'C:\Program Files\Android\Android Studio\jbr'
$PythonPreferred = 'C:\Users\DELL\AppData\Local\Programs\Python\Python314\python.exe'
$Apk = Join-Path $AndroidDir 'app\build\outputs\apk\debug\app-debug.apk'
$GradleProps = Join-Path $AndroidDir 'gradle\wrapper\gradle-wrapper.properties'
$GradleApp = Join-Path $AndroidDir 'app\build.gradle'
$JniDir = Join-Path $AndroidDir 'app\src\main\jniLibs\arm64-v8a'
$Package = 'me.generalsx.zh'
$Activity = 'me.generalsx.zh/.GameActivity'
$Marker = 'ZH_INIT_GATE_V8'
$SourceMarker = 'ZEROHOUR_ANDROID_INIT_GATE_V8'
$Log = 'C:\Users\DELL\Desktop\ZeroHour_INIT_GATE_V8_LOG.txt'
$PatchFile = Join-Path $env:TEMP 'ZeroHour_INIT_GATE_PATCH_V8.py'
$PatchUrl = 'https://raw.githubusercontent.com/xlucu/ZeroHour-2026-SourcePack/agent/mali-dualsrc-v3/13_BUILD_AND_DEVICE/ZeroHour_INIT_GATE_PATCH_V8.py'
$ExtractedMain = Join-Path $env:TEMP 'ZeroHour_V8_libmain.so'

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

function Invoke-Native([string]$Exe, [string[]]$NativeArgs, [string]$Label) {
    Write-Host ("> " + $Exe + ' ' + ($NativeArgs -join ' '))
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $Exe @NativeArgs
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0) { Fail "$Label failed with exit code $code" }
}

function Get-Hex4([string]$Path) {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] 4
        $n = $fs.Read($b,0,4)
        if ($n -lt 4) { return '' }
        return (($b | ForEach-Object { $_.ToString('X2') }) -join '')
    } finally {
        $fs.Dispose()
    }
}

function Assert-Elf([string]$Path) {
    Assert-Path $Path 'ELF candidate'
    $magic = Get-Hex4 $Path
    if ($magic -ne '7F454C46') { Fail "Not ELF: $Path (magic=$magic)" }
    Write-Host "ELF OK: $Path"
}

function Find-Gradle87 {
    $repoGradle = Join-Path $Repo 'tools\gradle\gradle-8.7\bin\gradle.bat'
    if (Test-Path -LiteralPath $repoGradle) { return $repoGradle }

    $cmd = Get-Command gradle.bat -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command gradle -ErrorAction SilentlyContinue }
    if ($cmd) {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $txt = (& $cmd.Source --version 2>&1 | Out-String)
        $code = $LASTEXITCODE
        $ErrorActionPreference = $old
        if ($code -eq 0 -and $txt -match 'Gradle\s+8\.7(\D|$)') { return $cmd.Source }
    }

    $gradleHome = Join-Path $env:USERPROFILE '.gradle'
    if (Test-Path -LiteralPath $gradleHome) {
        $cached = Get-ChildItem -LiteralPath $gradleHome -Recurse -Filter 'gradle.bat' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'gradle-8\.7\\bin\\gradle\.bat$' } |
            Select-Object -First 1
        if ($cached) { return $cached.FullName }
    }

    $toolsRoot = Join-Path $Repo 'tools\gradle'
    if (-not (Test-Path -LiteralPath $toolsRoot)) { New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null }
    $zipPath = Join-Path $toolsRoot 'gradle-8.7-bin.zip'
    $url = 'https://services.gradle.org/distributions/gradle-8.7-bin.zip'
    Write-Host ('Downloading pinned Gradle 8.7: ' + $url)
    Invoke-WebRequest -UseBasicParsing $url -OutFile $zipPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $toolsRoot -Force
    if (-not (Test-Path -LiteralPath $repoGradle)) { Fail 'Could not resolve pinned Gradle 8.7.' }
    return $repoGradle
}

Step 'Verify actual Zero Hour build route'
Assert-Path $Repo 'Current project'
Assert-Path $AndroidDir 'Android project'
Assert-Path $ZeroHourGameEngine 'Actual Zero Hour GameEngine.cpp'
Assert-Path $GradleProps 'Gradle wrapper properties'
Assert-Path $GradleApp 'Android app Gradle file'
Assert-Path $Adb 'adb'
Assert-Path $LlvmStrings 'NDK llvm-strings'
Assert-Path $JavaHome 'Android Studio JBR'
Assert-Elf (Join-Path $JniDir 'libdxvk_d3d8.so')
Assert-Elf (Join-Path $JniDir 'libdxvk_d3d9.so')
Assert-Elf (Join-Path $JniDir 'libSDL3.so')

$gradleText = [System.IO.File]::ReadAllText($GradleApp)
if ($gradleText -notmatch 'targets\s+"z_generals"') { Fail 'Android Gradle no longer targets z_generals.' }
if ($gradleText -notmatch 'RTS_BUILD_GENERALS=OFF') { Fail 'Android Gradle no longer disables Generals target as expected.' }
if ($gradleText -notmatch 'useLegacyPackaging\s*(=|\s)\s*false') { Fail 'useLegacyPackaging false missing.' }
$props = [System.IO.File]::ReadAllText($GradleProps)
if ($props -notmatch 'gradle-8\.7-bin\.zip') { Fail 'Project no longer pins Gradle 8.7.' }

$zhText = [System.IO.File]::ReadAllText($ZeroHourGameEngine)
if (-not $zhText.Contains('GX_LOG("GE::init: ThingFactory done")')) { Fail 'Actual Zero Hour source does not contain the proven ThingFactory marker.' }
if (-not $zhText.Contains('initSubsystem(TheUpgradeCenter,')) { Fail 'Actual Zero Hour source does not contain UpgradeCenter after ThingFactory.' }

if (Test-Path -LiteralPath $WrongGeneralsGameEngine) {
    $wrongText = [System.IO.File]::ReadAllText($WrongGeneralsGameEngine)
    if ($wrongText.Contains('ZEROHOUR_ANDROID_INIT_GATE_V7')) {
        Write-Host 'NOTE: old V7 marker exists only in Generals source; Android Zero Hour does not build that target.' -ForegroundColor Yellow
    }
}

$env:JAVA_HOME = $JavaHome
$env:ANDROID_SDK_ROOT = $Sdk
$env:ANDROID_HOME = $Sdk
$env:Path = (Join-Path $JavaHome 'bin') + ';' + (Join-Path $Sdk 'platform-tools') + ';' + $env:Path

Step 'Apply V8 diagnostics to GeneralsMD source'
$Python = $null
if (Test-Path -LiteralPath $PythonPreferred) {
    $Python = $PythonPreferred
} else {
    $py = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if ($py) { $Python = $py.Source }
}
if (-not $Python) { Fail 'Python was not found.' }
Write-Host ('Python: ' + $Python)
Invoke-WebRequest -UseBasicParsing $PatchUrl -OutFile $PatchFile
Invoke-Native $Python @($PatchFile) 'V8 Zero Hour source instrumentation'

$patched = [System.IO.File]::ReadAllText($ZeroHourGameEngine)
if (-not $patched.Contains($SourceMarker)) { Fail 'V8 source marker missing after patch.' }
if (-not $patched.Contains('GX_LOG("ZH_INIT_GATE_V8 BEGIN UpgradeCenter")')) { Fail 'V8 UpgradeCenter source marker missing after patch.' }

Step 'Resolve pinned Gradle 8.7'
$Gradle = Find-Gradle87
Write-Host ('Gradle: ' + $Gradle) -ForegroundColor Green
Invoke-Native $Gradle @('--version') 'Gradle version check'

Step 'Rebuild the real z_generals native target and APK'
$buildStart = Get-Date
Push-Location $AndroidDir
try {
    # Deliberately omit SAGE_SKIP_NATIVE_BUILD: V8 must compile into libmain.so.
    Invoke-Native $Gradle @(':app:assembleDebug','--stacktrace','--no-daemon') 'Gradle native/APK build'
} finally {
    Pop-Location
}
Assert-Path $Apk 'Debug APK'
$apkInfo = Get-Item -LiteralPath $Apk
if ($apkInfo.LastWriteTime -lt $buildStart.AddMinutes(-1)) { Fail 'APK timestamp does not reflect this V8 build.' }

Step 'Prove V8 is physically inside APK libmain.so'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipFile = [System.IO.Compression.ZipFile]::OpenRead($Apk)
try {
    $requiredEntries = @('lib/arm64-v8a/libmain.so','lib/arm64-v8a/libdxvk_d3d8.so','lib/arm64-v8a/libdxvk_d3d9.so','lib/arm64-v8a/libSDL3.so')
    foreach ($name in $requiredEntries) {
        $entry = $zipFile.Entries | Where-Object { $_.FullName -eq $name } | Select-Object -First 1
        if (-not $entry) { Fail "APK entry missing: $name" }
        $stream = $entry.Open()
        try {
            $b = New-Object byte[] 4
            [void]$stream.Read($b,0,4)
            $magic = (($b | ForEach-Object { $_.ToString('X2') }) -join '')
            if ($magic -ne '7F454C46') { Fail "APK entry is not ELF: $name (magic=$magic)" }
        } finally {
            $stream.Dispose()
        }
        if ($entry.CompressedLength -ne $entry.Length) { Fail "APK JNI library is compressed: $name" }
        Write-Host "APK ELF/STORED OK: $name"
    }

    $mainEntry = $zipFile.Entries | Where-Object { $_.FullName -eq 'lib/arm64-v8a/libmain.so' } | Select-Object -First 1
    if (Test-Path -LiteralPath $ExtractedMain) { Remove-Item -LiteralPath $ExtractedMain -Force }
    $inStream = $mainEntry.Open()
    $outStream = [System.IO.File]::Create($ExtractedMain)
    try {
        $inStream.CopyTo($outStream)
    } finally {
        $outStream.Dispose()
        $inStream.Dispose()
    }
} finally {
    $zipFile.Dispose()
}
Assert-Elf $ExtractedMain

$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$markerHit = @(& $LlvmStrings -a $ExtractedMain 2>&1 | Select-String -SimpleMatch $Marker | Select-Object -First 1)
$stringsCode = $LASTEXITCODE
$ErrorActionPreference = $old
if ($stringsCode -ne 0) { Fail "llvm-strings failed with exit code $stringsCode" }
if ($markerHit.Count -eq 0) { Fail 'V8 marker is NOT inside APK libmain.so; refusing to install a stale binary.' }
Write-Host ('APK libmain.so marker PROVEN: ' + $markerHit[0].Line) -ForegroundColor Green

Step 'Verify exactly one authorized Android device'
$deviceLines = & $Adb devices
$devices = @($deviceLines | Select-String "`tdevice$" | ForEach-Object { ($_.Line -split "`t")[0].Trim() })
if ($devices.Count -ne 1) { Fail "Exactly one authorized Android device is required. Found=$($devices.Count)" }
Write-Host ('Device: ' + $devices[0])

Step 'Install and launch without touching GameData'
Invoke-Native $Adb @('install','-r','-d',$Apk) 'adb install'
& $Adb logcat -c | Out-Null
Invoke-Native $Adb @('shell','am','force-stop',$Package) 'force-stop'
Invoke-Native $Adb @('shell','am','start','-n',$Activity) 'activity launch'
Start-Sleep -Seconds 10

Step 'Capture authoritative V8 runtime log'
'===== ZERO HOUR INIT GATE V8 =====' | Out-File -LiteralPath $Log -Encoding utf8
('Captured: ' + (Get-Date -Format o)) | Out-File -LiteralPath $Log -Encoding utf8 -Append
('APK: ' + $Apk) | Out-File -LiteralPath $Log -Encoding utf8 -Append
('APK_LIBMAIN_MARKER_PROVEN: ' + $markerHit[0].Line) | Out-File -LiteralPath $Log -Encoding utf8 -Append
'' | Out-File -LiteralPath $Log -Encoding utf8 -Append
'===== FULL LOGCAT =====' | Out-File -LiteralPath $Log -Encoding utf8 -Append

$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $Adb logcat -d -v time 2>&1 | Out-File -LiteralPath $Log -Encoding utf8 -Append
$logCode = $LASTEXITCODE
$ErrorActionPreference = $old
if ($logCode -ne 0) { Fail "adb logcat failed with exit code $logCode" }

Step 'First proven post-ThingFactory gate'
$interesting = @(Get-Content -LiteralPath $Log | Where-Object {
    $_ -match 'ZH_INIT_GATE_V8|GeneralsX.*GE::init|EXIT_SELF|Process me\.generalsx\.zh.*died|FATAL EXCEPTION|Fatal signal'
})
if ($interesting.Count -gt 0) {
    $interesting | Select-Object -Last 120 | ForEach-Object { Write-Host $_ }
    $v8 = @($interesting | Where-Object { $_ -match 'ZH_INIT_GATE_V8' })
    if ($v8.Count -gt 0) {
        Write-Host ''
        Write-Host ('LAST V8 MARKER: ' + $v8[-1]) -ForegroundColor Yellow
    } else {
        Fail 'V8 marker was proven inside APK libmain.so but no V8 runtime marker appeared in Logcat.'
    }
} else {
    Fail 'No relevant Zero Hour runtime markers were captured.'
}

Write-Host ''
Write-Host ('DIAGNOSTIC LOG: ' + $Log) -ForegroundColor Green
Write-Host 'The last V8 BEGIN/OK/CATCH marker is the only authority for the next fix.' -ForegroundColor Yellow
