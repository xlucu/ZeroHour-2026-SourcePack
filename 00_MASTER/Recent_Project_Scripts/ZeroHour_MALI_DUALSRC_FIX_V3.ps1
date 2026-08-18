$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root    = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$Build   = Join-Path $Root "tools\mali-dxvk\build-android-real"
$Jni     = Join-Path $Root "android\app\src\main\jniLibs\arm64-v8a"
$Android = Join-Path $Root "android"
$Apk     = Join-Path $Android "app\build\outputs\apk\debug\app-debug.apk"
$Adb     = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
$Ninja   = Join-Path $env:LOCALAPPDATA "Android\Sdk\cmake\3.31.6\bin\ninja.exe"
$Log     = Join-Path $env:USERPROFILE "Desktop\ZeroHour_MALI_LOG.txt"

$Package  = "me.generalsx.zh"
$Activity = "me.generalsx.zh/.GameActivity"

if (Test-Path $Log) { Remove-Item $Log -Force }

function Log([string]$Text = "") {
    $Text | Tee-Object -FilePath $Log -Append
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
    Log $Log
    throw $Text
}

function Get-Magic([string]$Path) {
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

function Is-Elf([string]$Path) {
    return ((Get-Magic $Path) -eq "7F454C46")
}

function Run-Native([string]$Exe, [string[]]$ArgList, [string]$Label) {
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

function Get-RealDxvkElf([string]$Subdir, [string]$BaseName) {
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
            return $item.FullName
        }
    }
    return $null
}

function Resolve-DxvkOutputs {
    Banner "2/7 RESOLVE THE REAL VERSIONED DXVK ELF OUTPUTS"

    $d3d8 = Get-RealDxvkElf "d3d8" "libdxvk_d3d8.so"
    $d3d9 = Get-RealDxvkElf "d3d9" "libdxvk_d3d9.so"

    if (-not $d3d8 -or -not $d3d9) {
        Log "A valid ELF was not found yet. Running ONE incremental Ninja build..."
        if (-not (Test-Path $Ninja)) { Fail "Ninja not found: $Ninja" }
        Run-Native $Ninja @("-C", $Build) "Incremental DXVK rebuild"

        $d3d8 = Get-RealDxvkElf "d3d8" "libdxvk_d3d8.so"
        $d3d9 = Get-RealDxvkElf "d3d9" "libdxvk_d3d9.so"
    }

    if (-not $d3d8) { Fail "No real ELF D3D8 output found under build-android-real\src\d3d8" }
    if (-not $d3d9) { Fail "No real ELF D3D9 output found under build-android-real\src\d3d9" }

    Log "SELECTED D3D8: $d3d8"
    Log "SELECTED D3D9: $d3d9"

    return @($d3d8, $d3d9)
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
        Fail "The Android dualSrcBlend V2 patch marker is missing. I will not repatch blindly."
    }

    Log "PROJECT: $Root"
    Log "dualSrcBlend ANDROID PATCH: PRESENT"
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"

    $resolved = Resolve-DxvkOutputs
    $BuiltD3D8 = $resolved[0]
    $BuiltD3D9 = $resolved[1]

    Banner "3/7 STAGE THE REAL ELF FILES UNDER CANONICAL JNI NAMES"

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
        Run-Native $gradlew @(":app:assembleDebug") "Gradle assembleDebug"
    }
    finally {
        Pop-Location
    }

    if (-not (Test-Path $Apk)) { Fail "APK was not produced: $Apk" }
    Log ("APK: {0} bytes" -f (Get-Item $Apk).Length)

    Banner "5/7 VERIFY JNI FILE CONTENT INSIDE APK"

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
            if ($magic -ne "7F454C46") { Fail "APK JNI entry is not ELF: $name" }
        }
    }
    finally {
        $zip.Dispose()
    }

    Banner "6/7 INSTALL AND LAUNCH - PRESERVE GAMEDATA"

    Run-Native $Adb @("start-server") "adb start-server"

    $devicesRaw = & $Adb devices 2>&1
    $authorized = @($devicesRaw | Select-String -Pattern "^[^\s]+\s+device$")

    if ($authorized.Count -ne 1) {
        Log ($devicesRaw -join [Environment]::NewLine)
        Fail "Exactly one authorized Android device is required. Found=$($authorized.Count)"
    }

    Run-Native $Adb @("install", "-r", "-d", $Apk) "adb install -r -d"
    Run-Native $Adb @("shell", "am", "force-stop", $Package) "Force-stop old process"

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Adb logcat -c 2>&1 | ForEach-Object { Log ([string]$_) }
        $null = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPref
    }

    Run-Native $Adb @("shell", "am", "start", "-n", $Activity) "Launch Zero Hour"

    Log "Waiting briefly for renderer initialization..."
    Start-Sleep -Seconds 12

    Banner "7/7 CAPTURE THE NEXT REAL RUNTIME GATE"

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = & $Adb logcat -d -v threadtime 2>&1
        $dumpCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPref
    }

    if ($dumpCode -ne 0) { Fail "adb logcat dump failed. ExitCode=$dumpCode" }

    $patterns = @(
        "ZH_ANDROID",
        "DXVK",
        "Dxvk",
        "Vulkan",
        "Mali",
        "Direct3DCreate8",
        "Skipping:",
        "required feature",
        "required extension",
        "No adapters found",
        "Failed to create device",
        "VK_EXT_robustness2",
        "robustBufferAccess2",
        "nullDescriptor",
        "dualSrcBlend",
        "FATAL",
        "Fatal signal",
        "SIGSEGV",
        "SIGABRT",
        "Scudo",
        "Abort message",
        "WW3D",
        "DX8Wrapper"
    )

    $regex = ($patterns | ForEach-Object { [regex]::Escape($_) }) -join "|"
    $filtered = @($raw | Select-String -Pattern $regex)

    if ($filtered.Count -gt 0) {
        $filtered | Select-Object -Last 500 | ForEach-Object { Log ([string]$_) }
    }
    else {
        Log "No renderer-pattern lines matched. Last 250 raw logcat lines follow:"
        $raw | Select-Object -Last 250 | ForEach-Object { Log ([string]$_) }
    }

    Log ""
    if (($filtered | Out-String) -match "Skipping:\s*Device does not support required feature") {
        Log "RESULT: dualSrcBlend staging/build blocker is fixed; runtime reached a Vulkan feature gate."
    }
    elseif (($filtered | Out-String) -match "No adapters found") {
        Log "RESULT: Runtime still rejected the adapter. The exact reason should be immediately above."
    }
    elseif (($filtered | Out-String) -match "Failed to create device") {
        Log "RESULT: Adapter/device creation advanced but failed. The exact reason should be immediately above."
    }
    else {
        Log "RESULT: No known adapter-gate signature was auto-classified. Use this same log for the next diagnosis."
    }

    Log ""
    Log "DONE."
    Log "SEND ME ONLY:"
    Log $Log
}
catch {
    if ($_.Exception.Message -notmatch "^FAILED:") {
        try { Log ("ERROR: " + $_.Exception.Message) } catch {}
    }
    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $Log
    exit 1
}
