$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root    = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$Build   = Join-Path $Root "tools\mali-dxvk\build-android-real"
$Jni     = Join-Path $Root "android\app\src\main\jniLibs\arm64-v8a"
$Android = Join-Path $Root "android"
$Apk     = Join-Path $Android "app\build\outputs\apk\debug\app-debug.apk"
$Adb     = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
$Ninja   = Join-Path $env:LOCALAPPDATA "Android\Sdk\cmake\3.31.6\bin\ninja.exe"
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

function Find-RealDxvkElf {
    param(
        [Parameter(Mandatory=$true)][string]$Subdir,
        [Parameter(Mandatory=$true)][string]$BaseName
    )

    $dir = Join-Path $Build "src\$Subdir"
    if (-not (Test-Path $dir)) {
        return $null
    }

    $items = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$BaseName*" } |
        Sort-Object @{Expression="LastWriteTime";Descending=$true}, @{Expression="Length";Descending=$true})

    foreach ($item in $items) {
        $magic = Get-Magic $item.FullName
        Log ("CANDIDATE: {0} | {1} bytes | MAGIC={2}" -f $item.FullName, $item.Length, $magic)

        if ($magic -eq "7F454C46") {
            return [string]$item.FullName
        }
    }

    return $null
}

try {
    Banner "1/7 VERIFY CURRENT PATCHED STATE"

    if (-not (Test-Path $Root))  { Fail "Project root not found: $Root" }
    if (-not (Test-Path $Build)) { Fail "DXVK build folder not found: $Build" }
    if (-not (Test-Path $Jni))   { Fail "JNI folder not found: $Jni" }
    if (-not (Test-Path $Adb))   { Fail "adb not found: $Adb" }

    $src = Join-Path $Root "tools\mali-dxvk\actual-dxvk-source\src\dxvk\dxvk_device_info.cpp"
    if (-not (Test-Path $src)) { Fail "dxvk_device_info.cpp not found" }

    $srcText = [System.IO.File]::ReadAllText($src)
    if ($srcText -notmatch "ZEROHOUR_ANDROID_MALI_DUALSRC_OPTIONAL") {
        Fail "The Android dualSrcBlend V2 patch marker is missing. Refusing to patch blindly."
    }

    Log "PROJECT: $Root"
    Log "dualSrcBlend ANDROID PATCH: PRESENT"
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"

    Banner "2/7 RESOLVE REAL VERSIONED DXVK ELF OUTPUTS"

    $BuiltD3D8 = Find-RealDxvkElf -Subdir "d3d8" -BaseName "libdxvk_d3d8.so"
    $BuiltD3D9 = Find-RealDxvkElf -Subdir "d3d9" -BaseName "libdxvk_d3d9.so"

    if ([string]::IsNullOrWhiteSpace($BuiltD3D8) -or [string]::IsNullOrWhiteSpace($BuiltD3D9)) {
        Log "A valid output is missing. Running ONE incremental DXVK build only..."

        if (-not (Test-Path $Ninja)) { Fail "Ninja not found: $Ninja" }

        Run-Native -Exe $Ninja -ArgList @("-C", $Build) -Label "Incremental DXVK rebuild"

        $BuiltD3D8 = Find-RealDxvkElf -Subdir "d3d8" -BaseName "libdxvk_d3d8.so"
        $BuiltD3D9 = Find-RealDxvkElf -Subdir "d3d9" -BaseName "libdxvk_d3d9.so"
    }

    if ([string]::IsNullOrWhiteSpace($BuiltD3D8)) {
        Fail "No real ELF D3D8 output found."
    }
    if ([string]::IsNullOrWhiteSpace($BuiltD3D9)) {
        Fail "No real ELF D3D9 output found."
    }

    if (-not (Test-Path -LiteralPath $BuiltD3D8)) { Fail "Selected D3D8 path does not exist: $BuiltD3D8" }
    if (-not (Test-Path -LiteralPath $BuiltD3D9)) { Fail "Selected D3D9 path does not exist: $BuiltD3D9" }

    Log "SELECTED D3D8: $BuiltD3D8"
    Log "SELECTED D3D9: $BuiltD3D9"

    Banner "3/7 STAGE REAL ELF FILES UNDER CANONICAL JNI NAMES"

    $StageD3D8 = Join-Path $Jni "libdxvk_d3d8.so"
    $StageD3D9 = Join-Path $Jni "libdxvk_d3d9.so"

    Copy-Item -LiteralPath $BuiltD3D8 -Destination $StageD3D8 -Force
    Copy-Item -LiteralPath $BuiltD3D9 -Destination $StageD3D9 -Force

    $m8 = Get-Magic $StageD3D8
    $m9 = Get-Magic $StageD3D9

    Log "STAGED D3D8 MAGIC: $m8"
    Log "STAGED D3D9 MAGIC: $m9"

    if ($m8 -ne "7F454C46") { Fail "Staged D3D8 is not ELF." }
    if ($m9 -ne "7F454C46") { Fail "Staged D3D9 is not ELF." }

    Banner "4/7 BUILD APK ONLY"

    $gradlew = Join-Path $Android "gradlew.bat"
    if (-not (Test-Path $gradlew)) { Fail "gradlew.bat not found: $gradlew" }

    Push-Location $Android
    try {
        Run-Native -Exe $gradlew -ArgList @(":app:assembleDebug") -Label "Gradle assembleDebug"
    }
    finally {
        Pop-Location
    }

    if (-not (Test-Path $Apk)) { Fail "APK was not produced: $Apk" }
    Log ("APK: {0} bytes" -f (Get-Item $Apk).Length)

    Banner "5/7 VERIFY JNI ELF CONTENT INSIDE APK"

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

            Log ("APK ENTRY: {0} | {1} bytes | MAGIC={2}" -f $name, $entry.Length, $magic)

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

    Banner "7/7 CAPTURE NEXT REAL RUNTIME GATE"

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
        $filtered | Select-Object -Last 600 | ForEach-Object { Log ([string]$_) }
    }
    else {
        Log "No renderer-pattern lines matched. Last 300 raw logcat lines follow:"
        $raw | Select-Object -Last 300 | ForEach-Object { Log ([string]$_) }
    }

    $joined = ($filtered | Out-String)

    Log ""

    if ($joined -match "dualSrcBlend" -and $joined -match "Skipping:") {
        Log "RESULT: dualSrcBlend is STILL reported by runtime. We will verify which library the APK/process actually loads."
    }
    elseif ($joined -match "Skipping:\s*Device does not support required feature") {
        Log "RESULT: dualSrcBlend gate is gone. Runtime reached the NEXT Vulkan feature gate."
    }
    elseif ($joined -match "VK_EXT_robustness2|robustBufferAccess2|nullDescriptor") {
        Log "RESULT: Runtime reached the robustness/null-descriptor path. Next step is Molotov fallback comparison, not blind disabling."
    }
    elseif ($joined -match "Failed to create device") {
        Log "RESULT: Runtime advanced to device creation but failed. Read the exact reason above."
    }
    elseif ($joined -match "No adapters found") {
        Log "RESULT: Runtime still rejected the adapter. Read the exact reason immediately above."
    }
    else {
        Log "RESULT: No known adapter gate was auto-classified. The captured log is the source for the next step."
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
