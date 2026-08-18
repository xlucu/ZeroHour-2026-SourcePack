$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root    = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$Android = Join-Path $Root "android"
$AppDir  = Join-Path $Android "app"
$Jni     = Join-Path $AppDir "src\main\jniLibs\arm64-v8a"
$Adb     = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
$LogFile = Join-Path $env:USERPROFILE "Desktop\ZeroHour_MALI_LOG.txt"

$Package  = "me.generalsx.zh"
$Activity = "me.generalsx.zh/.GameActivity"

if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

function Log([string]$Text = "") {
    Add-Content -LiteralPath $LogFile -Value $Text -Encoding UTF8
    Write-Host $Text
}

function Banner([string]$Text) {
    Log ""
    Log "============================================================"
    Log $Text
    Log "============================================================"
}

function Fail([string]$Text) {
    Log ""
    Log "FAILED: $Text"
    Log "SEND ME ONLY:"
    Log $LogFile
    throw $Text
}

function Get-Magic([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "EMPTY" }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $b = New-Object byte[] 4
            $n = $fs.Read($b, 0, 4)
            if ($n -ne 4) { return "SHORT" }
            return (($b | ForEach-Object { $_.ToString("X2") }) -join "")
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        return "READERR"
    }
}

function Run-Native {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$ArgList,
        [Parameter(Mandatory=$true)][string]$Label
    )

    Log ">> $Label"
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Exe @ArgList 2>&1 | ForEach-Object { Log ([string]$_) }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPref
    }

    if ($code -ne 0) {
        Fail "$Label failed. ExitCode=$code"
    }
}

function Patch-OboeFullDuplexHeader([string]$HeaderPath) {
    Log "OBOE HEADER: $HeaderPath"

    $text = [System.IO.File]::ReadAllText($HeaderPath)

    if ($text -match 'DataCallbackResult\s+onAudioReady\s*\([\s\S]{0,400}?\)\s*override\s*\{') {
        Log "OBOE onAudioReady override PATCH: ALREADY PRESENT"
        return
    }

    $start = $text.IndexOf("DataCallbackResult onAudioReady(")
    if ($start -lt 0) {
        Fail "Could not find FullDuplexStream::onAudioReady in $HeaderPath"
    }

    $windowLength = [Math]::Min(600, $text.Length - $start)
    $window = $text.Substring($start, $windowLength)

    $match = [regex]::Match(
        $window,
        'DataCallbackResult\s+onAudioReady\s*\([\s\S]*?int(?:32_t)?\s+numFrames\s*\)\s*\{'
    )

    if (-not $match.Success) {
        Fail "Found onAudioReady name, but exact function signature was not recognized safely in $HeaderPath"
    }

    $matchedText = $match.Value

    if ($matchedText -match '\boverride\b') {
        Log "OBOE onAudioReady override PATCH: ALREADY PRESENT"
        return
    }

    $patchedMatch = [regex]::Replace(
        $matchedText,
        '\)\s*\{$',
        ') override {',
        1
    )

    if ($patchedMatch -eq $matchedText) {
        Fail "Could not add override safely in $HeaderPath"
    }

    $absoluteIndex = $start + $match.Index
    $newText =
        $text.Substring(0, $absoluteIndex) +
        $patchedMatch +
        $text.Substring($absoluteIndex + $match.Length)

    $backup = "$HeaderPath.before_zh_oboe_override.bak"
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $HeaderPath -Destination $backup -Force
        Log "BACKUP CREATED: $backup"
    }

    [System.IO.File]::WriteAllText(
        $HeaderPath,
        $newText,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $verify = [System.IO.File]::ReadAllText($HeaderPath)
    if ($verify -notmatch 'DataCallbackResult\s+onAudioReady\s*\([\s\S]{0,400}?\)\s*override\s*\{') {
        Fail "Oboe override verification failed: $HeaderPath"
    }

    Log "OBOE onAudioReady override PATCH: APPLIED"
}

try {
    Banner "1/7 VERIFY EXISTING DXVK STAGING"

    if (-not (Test-Path $Root)) { Fail "Project root not found: $Root" }
    if (-not (Test-Path $AppDir)) { Fail "Android app directory not found: $AppDir" }
    if (-not (Test-Path $Adb)) { Fail "adb not found: $Adb" }

    $d3d8 = Join-Path $Jni "libdxvk_d3d8.so"
    $d3d9 = Join-Path $Jni "libdxvk_d3d9.so"
    $sdl3 = Join-Path $Jni "libSDL3.so"

    foreach ($lib in @($d3d8, $d3d9, $sdl3)) {
        if (-not (Test-Path -LiteralPath $lib)) {
            Fail "Required staged library missing: $lib"
        }

        $magic = Get-Magic $lib
        Log ("{0} MAGIC={1}" -f (Split-Path $lib -Leaf), $magic)

        if ($magic -ne "7F454C46") {
            Fail "Required staged library is not ELF: $lib"
        }
    }

    Log "DXVK/SDL3 STAGING: VALID"
    Log "NO DXVK REBUILD"
    Log "NO GAMEDATA RECOPY"

    Banner "2/7 LOCATE FETCHED OBOE HEADER"

    $cxxDebug = Join-Path $AppDir ".cxx\Debug"
    if (-not (Test-Path $cxxDebug)) {
        Fail "Current Debug native build tree not found: $cxxDebug"
    }

    $headers = @(Get-ChildItem -LiteralPath $cxxDebug -Filter "FullDuplexStream.h" -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match '[\\/]_deps[\\/]oboe-src[\\/]include[\\/]oboe[\\/]FullDuplexStream\.h$' -and
            $_.FullName -match 'arm64-v8a'
        } |
        Sort-Object @{Expression="LastWriteTime";Descending=$true})

    if ($headers.Count -eq 0) {
        Fail "Could not find fetched Oboe FullDuplexStream.h under the current Debug arm64 build tree."
    }

    Log "OBOE HEADER COUNT: $($headers.Count)"
    foreach ($h in $headers) {
        Log "FOUND: $($h.FullName)"
    }

    Banner "3/7 PATCH ONLY onAudioReady override"

    foreach ($h in $headers) {
        Patch-OboeFullDuplexHeader -HeaderPath $h.FullName
    }

    Banner "4/7 AUTO-DETECT GRADLE AND RESUME INCREMENTAL BUILD"

    $wrapperCandidates = @(
        (Join-Path $Android "gradlew.bat"),
        (Join-Path $Root "gradlew.bat")
    )

    $gradlew = $null

    foreach ($candidate in $wrapperCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            $gradlew = [string]$candidate
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($gradlew)) {
        $foundWrappers = @(Get-ChildItem -LiteralPath $Root -Filter "gradlew.bat" -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object @{Expression="FullName";Descending=$false})

        foreach ($item in $foundWrappers) {
            Log "GRADLE WRAPPER CANDIDATE: $($item.FullName)"
        }

        if ($foundWrappers.Count -gt 0) {
            $gradlew = [string]$foundWrappers[0].FullName
        }
    }

    if ([string]::IsNullOrWhiteSpace($gradlew)) {
        Fail "No gradlew.bat found under project root."
    }

    $projectDir = $Android
    if (-not (Test-Path (Join-Path $projectDir "settings.gradle")) -and
        -not (Test-Path (Join-Path $projectDir "settings.gradle.kts"))) {

        $settingsCandidates = @(Get-ChildItem -LiteralPath $Root -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "settings.gradle" -or $_.Name -eq "settings.gradle.kts" })

        $projectDir = $null
        foreach ($s in $settingsCandidates) {
            $candidateDir = $s.Directory.FullName
            if (Test-Path (Join-Path $candidateDir "app")) {
                $projectDir = [string]$candidateDir
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($projectDir)) {
            Fail "Could not locate Gradle project directory."
        }
    }

    Log "GRADLE WRAPPER: $gradlew"
    Log "GRADLE PROJECT: $projectDir"
    Log "BUILD MODE: INCREMENTAL (no clean)"

    Push-Location $projectDir
    try {
        Run-Native -Exe $gradlew -ArgList @("-p", $projectDir, ":app:assembleDebug") -Label "Gradle assembleDebug incremental"
    }
    finally {
        Pop-Location
    }

    Banner "5/7 LOCATE AND VERIFY APK"

    $apkCandidates = @(Get-ChildItem -LiteralPath $projectDir -Filter "app-debug.apk" -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object @{Expression="LastWriteTime";Descending=$true}, @{Expression="Length";Descending=$true})

    if ($apkCandidates.Count -eq 0) {
        Fail "Gradle succeeded but app-debug.apk was not found."
    }

    $Apk = [string]$apkCandidates[0].FullName
    Log ("APK: {0} | {1} bytes" -f $Apk, (Get-Item -LiteralPath $Apk).Length)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Apk)
    try {
        foreach ($name in @(
            "lib/arm64-v8a/libdxvk_d3d8.so",
            "lib/arm64-v8a/libdxvk_d3d9.so",
            "lib/arm64-v8a/libSDL3.so"
        )) {
            $entry = $zip.GetEntry($name)
            if ($null -eq $entry) { Fail "APK entry missing: $name" }

            $stream = $entry.Open()
            try {
                $buf = New-Object byte[] 4
                $count = $stream.Read($buf, 0, 4)
                if ($count -ne 4) { Fail "APK entry too short: $name" }
                $magic = (($buf | ForEach-Object { $_.ToString("X2") }) -join "")
            }
            finally {
                $stream.Dispose()
            }

            Log ("APK ENTRY: {0} | MAGIC={1}" -f $name, $magic)
            if ($magic -ne "7F454C46") {
                Fail "APK JNI entry is not ELF: $name"
            }
        }
    }
    finally {
        $zip.Dispose()
    }

    Banner "6/7 INSTALL AND LAUNCH - PRESERVE GAMEDATA"

    Run-Native -Exe $Adb -ArgList @("start-server") -Label "adb start-server"

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $devicesRaw = @(& $Adb devices 2>&1)
        $devCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPref
    }

    if ($devCode -ne 0) {
        $devicesRaw | ForEach-Object { Log ([string]$_) }
        Fail "adb devices failed. ExitCode=$devCode"
    }

    $authorized = @($devicesRaw | Select-String -Pattern "^[^\s]+\s+device$")
    if ($authorized.Count -ne 1) {
        $devicesRaw | ForEach-Object { Log ([string]$_) }
        Fail "Exactly one authorized Android device is required. Found=$($authorized.Count)"
    }

    Run-Native -Exe $Adb -ArgList @("install", "-r", "-d", $Apk) -Label "adb install -r -d"
    Run-Native -Exe $Adb -ArgList @("shell", "am", "force-stop", $Package) -Label "Force-stop old process"

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Adb logcat -c 2>&1 | ForEach-Object { Log ([string]$_) }
        $clearCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPref
    }

    if ($clearCode -ne 0) {
        Fail "adb logcat -c failed. ExitCode=$clearCode"
    }

    Run-Native -Exe $Adb -ArgList @("shell", "am", "start", "-n", $Activity) -Label "Launch Zero Hour"

    Log "Waiting 12 seconds for renderer initialization..."
    Start-Sleep -Seconds 12

    Banner "7/7 CAPTURE NEXT REAL RUNTIME/BUILD GATE"

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = @(& $Adb logcat -d -v threadtime 2>&1)
        $dumpCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPref
    }

    if ($dumpCode -ne 0) {
        Fail "adb logcat dump failed. ExitCode=$dumpCode"
    }

    $regex = "ZH_ANDROID|DXVK|Dxvk|Vulkan|Mali|Direct3DCreate8|Skipping:|required feature|required extension|No adapters found|Failed to create device|VK_EXT_robustness2|robustBufferAccess2|nullDescriptor|dualSrcBlend|FATAL|Fatal signal|SIGSEGV|SIGABRT|Scudo|Abort message|WW3D|DX8Wrapper"

    $filtered = @($raw | Select-String -Pattern $regex)

    if ($filtered.Count -gt 0) {
        $filtered | Select-Object -Last 700 | ForEach-Object { Log ([string]$_) }
    }
    else {
        Log "No renderer-pattern lines matched. Last 350 raw logcat lines follow:"
        $raw | Select-Object -Last 350 | ForEach-Object { Log ([string]$_) }
    }

    $joined = ($filtered | Out-String)

    Log ""
    if ($joined -match "dualSrcBlend" -and $joined -match "Skipping:") {
        Log "RESULT: Runtime still reports dualSrcBlend. Next step is verifying the actually loaded DXVK binary."
    }
    elseif ($joined -match "Skipping:\s*Device does not support required feature") {
        Log "RESULT: dualSrcBlend gate is gone. Runtime reached the NEXT Vulkan feature gate."
    }
    elseif ($joined -match "VK_EXT_robustness2|robustBufferAccess2|nullDescriptor") {
        Log "RESULT: Runtime reached robustness/null-descriptor path. Next step is Molotov fallback comparison."
    }
    elseif ($joined -match "Failed to create device") {
        Log "RESULT: Runtime advanced to device creation but failed. Exact reason is above."
    }
    elseif ($joined -match "No adapters found") {
        Log "RESULT: Runtime still rejected adapter. Exact reason is above."
    }
    else {
        Log "RESULT: Build/install/launch completed. Read captured runtime lines above for the next gate."
    }

    Log ""
    Log "DONE."
    Log "SEND ME ONLY:"
    Log $LogFile
}
catch {
    try {
        if ($_.Exception.Message -notmatch "^FAILED:") {
            Log ("ERROR: " + $_.Exception.Message)
        }
    }
    catch {}

    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LogFile
    exit 1
}
