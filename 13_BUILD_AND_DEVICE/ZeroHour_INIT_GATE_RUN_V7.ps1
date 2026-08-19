# ZeroHour_INIT_GATE_RUN_V7.ps1
# One-command continuation from the proven post-dualSrcBlend runtime state.
# Applies diagnostics only, rebuilds the real native engine, packages/installs,
# runs on the connected phone, and captures the exact first init gate failure.
# Windows PowerShell 5.1 compatible.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Repo = 'C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN'
$AndroidDir = Join-Path $Repo 'android'
$Sdk = 'C:\Users\DELL\AppData\Local\Android\Sdk'
$Adb = Join-Path $Sdk 'platform-tools\adb.exe'
$JavaHome = 'C:\Program Files\Android\Android Studio\jbr'
$PythonPreferred = 'C:\Users\DELL\AppData\Local\Programs\Python\Python314\python.exe'
$Apk = Join-Path $AndroidDir 'app\build\outputs\apk\debug\app-debug.apk'
$GradleProps = Join-Path $AndroidDir 'gradle\wrapper\gradle-wrapper.properties'
$GradleApp = Join-Path $AndroidDir 'app\build.gradle'
$JniDir = Join-Path $AndroidDir 'app\src\main\jniLibs\arm64-v8a'
$Package = 'me.generalsx.zh'
$Activity = 'me.generalsx.zh/.GameActivity'
$CombinedLog = 'C:\Users\DELL\Desktop\ZeroHour_INIT_GATE_V7_LOG.txt'
$PatchFile = Join-Path $env:TEMP 'ZeroHour_INIT_GATE_PATCH_V7.py'
$PatchUrl = 'https://raw.githubusercontent.com/xlucu/ZeroHour-2026-SourcePack/agent/mali-dualsrc-v3/13_BUILD_AND_DEVICE/ZeroHour_INIT_GATE_PATCH_V7.py'

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
    $zip = Join-Path $toolsRoot 'gradle-8.7-bin.zip'
    $url = 'https://services.gradle.org/distributions/gradle-8.7-bin.zip'
    Write-Host ('Downloading pinned Gradle 8.7: ' + $url)
    Invoke-WebRequest -UseBasicParsing $url -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $toolsRoot -Force
    if (-not (Test-Path -LiteralPath $repoGradle)) { Fail 'Could not resolve pinned Gradle 8.7.' }
    return $repoGradle
}

Step 'Verify environment and preserved DXVK state'
Assert-Path $Repo 'Current project'
Assert-Path $AndroidDir 'Android project'
Assert-Path $Adb 'adb'
Assert-Path $JavaHome 'Android Studio JBR'
Assert-Path $GradleProps 'Gradle wrapper properties'
Assert-Path $GradleApp 'Android app Gradle file'
Assert-Elf (Join-Path $JniDir 'libdxvk_d3d8.so')
Assert-Elf (Join-Path $JniDir 'libdxvk_d3d9.so')
Assert-Elf (Join-Path $JniDir 'libSDL3.so')

$props = [System.IO.File]::ReadAllText($GradleProps)
if ($props -notmatch 'gradle-8\.7-bin\.zip') { Fail 'Project no longer pins Gradle 8.7.' }
$gradleText = [System.IO.File]::ReadAllText($GradleApp)
if ($gradleText -notmatch 'useLegacyPackaging\s*(=|\s)\s*false') { Fail 'useLegacyPackaging false missing.' }

$env:JAVA_HOME = $JavaHome
$env:ANDROID_SDK_ROOT = $Sdk
$env:ANDROID_HOME = $Sdk
$env:Path = (Join-Path $JavaHome 'bin') + ';' + (Join-Path $Sdk 'platform-tools') + ';' + $env:Path

Step 'Resolve Python and apply diagnostic-only source patch'
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
Invoke-Native $Python @($PatchFile) 'V7 source instrumentation'

Step 'Resolve pinned Gradle 8.7'
$Gradle = Find-Gradle87
Write-Host ('Gradle: ' + $Gradle) -ForegroundColor Green
Invoke-Native $Gradle @('--version') 'Gradle version check'

Step 'Rebuild real native engine and APK'
$buildStart = Get-Date
Push-Location $AndroidDir
try {
    # No SAGE_SKIP_NATIVE_BUILD here: the diagnostic changes must enter libmain.so.
    Invoke-Native $Gradle @(':app:assembleDebug','--stacktrace','--no-daemon') 'Gradle native/APK build'
} finally {
    Pop-Location
}
Assert-Path $Apk 'Debug APK'
$apkInfo = Get-Item -LiteralPath $Apk
if ($apkInfo.LastWriteTime -lt $buildStart.AddMinutes(-1)) { Fail 'APK timestamp does not reflect this build.' }

Step 'Verify APK native payload'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipFile = [System.IO.Compression.ZipFile]::OpenRead($Apk)
try {
    foreach ($name in @('lib/arm64-v8a/libmain.so','lib/arm64-v8a/libdxvk_d3d8.so','lib/arm64-v8a/libdxvk_d3d9.so','lib/arm64-v8a/libSDL3.so')) {
        $entry = $zipFile.Entries | Where-Object { $_.FullName -eq $name } | Select-Object -First 1
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
} finally {
    $zipFile.Dispose()
}

Step 'Verify exactly one authorized Android device'
$deviceLines = & $Adb devices
$devices = @($deviceLines | Select-String "`tdevice$" | ForEach-Object { ($_.Line -split "`t")[0].Trim() })
if ($devices.Count -ne 1) { Fail "Exactly one authorized Android device is required. Found=$($devices.Count)" }
Write-Host ('Device: ' + $devices[0])

Step 'Install and run without touching original GameData'
Invoke-Native $Adb @('install','-r','-d',$Apk) 'adb install'

# Clear only our diagnostic file inside the debug app sandbox. Ignore absence.
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $Adb shell run-as $Package rm -f files/GameData/ZeroHour_InitGate.txt | Out-Null
$ErrorActionPreference = $old

& $Adb logcat -c | Out-Null
Invoke-Native $Adb @('shell','am','force-stop',$Package) 'force-stop'
Invoke-Native $Adb @('shell','am','start','-n',$Activity) 'activity launch'
Start-Sleep -Seconds 10

Step 'Capture init gate file and Logcat'
'===== ZERO HOUR INIT GATE V7 =====' | Out-File -LiteralPath $CombinedLog -Encoding utf8
('Captured: ' + (Get-Date -Format o)) | Out-File -LiteralPath $CombinedLog -Encoding utf8 -Append
'' | Out-File -LiteralPath $CombinedLog -Encoding utf8 -Append
'===== INTERNAL INIT GATE FILE =====' | Out-File -LiteralPath $CombinedLog -Encoding utf8 -Append

$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$diag = & $Adb shell run-as $Package cat files/GameData/ZeroHour_InitGate.txt 2>&1
$diagCode = $LASTEXITCODE
$ErrorActionPreference = $old
if ($diagCode -eq 0) {
    $diag | Out-File -LiteralPath $CombinedLog -Encoding utf8 -Append
} else {
    ('run-as diagnostic read failed, exit=' + $diagCode) | Out-File -LiteralPath $CombinedLog -Encoding utf8 -Append
    $diag | Out-File -LiteralPath $CombinedLog -Encoding utf8 -Append
}

'' | Out-File -LiteralPath $CombinedLog -Encoding utf8 -Append
'===== FULL LOGCAT =====' | Out-File -LiteralPath $CombinedLog -Encoding utf8 -Append
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $Adb logcat -d -v time 2>&1 | Out-File -LiteralPath $CombinedLog -Encoding utf8 -Append
$logCode = $LASTEXITCODE
$ErrorActionPreference = $old
if ($logCode -ne 0) { Fail "adb logcat failed with exit code $logCode" }

Step 'Proven next gate'
if ($diagCode -eq 0 -and $diag.Count -gt 0) {
    Write-Host 'Init gate sequence:'
    $diag | ForEach-Object { Write-Host ('  ' + $_) }
    Write-Host ''
    Write-Host ('LAST INIT MARKER: ' + $diag[-1]) -ForegroundColor Yellow
} else {
    Write-Host 'Internal gate file was not readable; full Logcat was still captured.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host ('DIAGNOSTIC LOG: ' + $CombinedLog) -ForegroundColor Green
Write-Host 'Do not infer the cause beyond the last proven BEGIN/OK/CATCH marker.' -ForegroundColor Yellow
