$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - NATIVE LIB REPAIR
#
# Current smoking gun from Android logcat:
#   libdxvk_d3d9.so has bad ELF magic: 504b0304
#
# 50 4B 03 04 = ZIP/APK header, not an ELF shared library.
#
# This script:
#   1) checks the REAL magic bytes of staged + built .so files
#   2) repairs staged d3d8/d3d9 from Meson outputs if needed
#   3) enforces non-legacy JNI packaging (uncompressed/page-aligned)
#   4) cleans/repackages ONLY the APK (no engine rebuild)
#   5) verifies APK entries are real ELF files
#   6) installs as update and launches
#
# NO libmain.so rebuild.
# NO GameData recopy.
# NO uninstall.
#
# ONE LOG:
#   C:\Users\DELL\Desktop\ZeroHour_NATIVE_LIB_LOG.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$WORK = "$ROOT\tools\mali-dxvk"
$DXVKBUILD = "$WORK\build-android-real"

$SDK = "$env:LOCALAPPDATA\Android\Sdk"
$ADB = "$SDK\platform-tools\adb.exe"
$ZIPALIGN = "$SDK\build-tools\35.0.0\zipalign.exe"

$JBR = "C:\Program Files\Android\Android Studio\jbr"
$GRADLE = "$ROOT\tools\gradle-8.7\bin\gradle.bat"
$BUILD_GRADLE = "$ROOT\android\app\build.gradle"
$APK = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"

$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$STAGED8 = "$JNI\libdxvk_d3d8.so"
$STAGED9 = "$JNI\libdxvk_d3d9.so"
$SDL3 = "$JNI\libSDL3.so"

$BUILT8 = "$DXVKBUILD\src\d3d8\libdxvk_d3d8.so"
$BUILT9 = "$DXVKBUILD\src\d3d9\libdxvk_d3d9.so"

$WSI = "$WORK\actual-dxvk-source\src\wsi\sdl3\wsi_platform_sdl3.cpp"
$WSI_BACKUP = "$WSI.before_android_direct_dlopen.bak"

$PYTHON = "C:\Users\DELL\AppData\Local\Programs\Python\Python314\python.exe"

$LOG = "$env:USERPROFILE\Desktop\ZeroHour_NATIVE_LIB_LOG.txt"

"" | Out-File $LOG -Encoding utf8

function Log([string]$Text) {
    Write-Host $Text
    $Text | Out-File $LOG -Append -Encoding utf8
}

function Step([string]$Text) {
    Log ""
    Log "============================================================"
    Log $Text
    Log "============================================================"
}

function Fail([string]$Text) {
    Log ""
    Log "FAILED: $Text"
    Log "SEND ME ONLY:"
    Log $LOG
    throw $Text
}

function Run-Native {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$false)][string[]]$ArgumentList = @(),
        [switch]$Quiet
    )

    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $out = & $Exe @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
    }

    $lines = @()
    foreach ($x in @($out)) {
        if ($null -ne $x) {
            $s = $x.ToString()
            $lines += $s
            if (!$Quiet) { Log $s }
        }
    }

    return [pscustomobject]@{
        Code = $code
        Text = ($lines -join "`r`n")
    }
}

function Get-Magic([string]$Path) {
    if (!(Test-Path $Path)) { return "MISSING" }

    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 8
        $n = $fs.Read($buf,0,8)
    }
    finally {
        $fs.Dispose()
    }

    if ($n -le 0) { return "EMPTY" }

    return (($buf[0..($n-1)] | ForEach-Object { $_.ToString("X2") }) -join "")
}

function Is-Elf([string]$Path) {
    if (!(Test-Path $Path)) { return $false }
    $m = Get-Magic $Path
    return $m.StartsWith("7F454C46")
}

try {
    Step "1/7 VERIFY FILES + PHONE"

    foreach ($p in @(
        $ROOT,$DXVKBUILD,$ADB,$ZIPALIGN,$JBR,$GRADLE,
        $BUILD_GRADLE,$JNI,$STAGED8,$STAGED9,$SDL3,
        $BUILT8,$BUILT9,$PYTHON
    )) {
        if (!(Test-Path $p)) {
            Fail "Missing required path: $p"
        }
    }

    $env:JAVA_HOME = $JBR
    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:Path = "$JBR\bin;$SDK\platform-tools;$SDK\build-tools\35.0.0;$env:Path"

    Run-Native -Exe $ADB -ArgumentList @("start-server") -Quiet | Out-Null

    $devices = & $ADB devices
    $authorized = @(
        $devices |
        Select-Object -Skip 1 |
        Where-Object { $_ -match "^\S+\s+device$" }
    )

    if ($authorized.Count -ne 1) {
        Fail "Exactly one authorized Android device required. Found=$($authorized.Count)"
    }

    Log "DEVICE: $((& $ADB shell getprop ro.product.model).Trim())"
    Log "ABI: $((& $ADB shell getprop ro.product.cpu.abi).Trim())"
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"


    Step "2/7 CHECK REAL MAGIC BYTES"

    $targets = @(
        [pscustomobject]@{Name="STAGED D3D8"; Path=$STAGED8},
        [pscustomobject]@{Name="STAGED D3D9"; Path=$STAGED9},
        [pscustomobject]@{Name="STAGED SDL3"; Path=$SDL3},
        [pscustomobject]@{Name="BUILT D3D8"; Path=$BUILT8},
        [pscustomobject]@{Name="BUILT D3D9"; Path=$BUILT9}
    )

    foreach ($t in $targets) {
        $magic = Get-Magic $t.Path
        $size = if (Test-Path $t.Path) { (Get-Item $t.Path).Length } else { 0 }
        Log ("{0}: magic={1} size={2}" -f $t.Name,$magic,$size)
    }

    if (!(Is-Elf $SDL3)) {
        Fail "Staged libSDL3.so is not an ELF shared library."
    }

    if (!(Is-Elf $BUILT8)) {
        Fail "Meson-built libdxvk_d3d8.so is not ELF. Do not package it."
    }

    if (!(Is-Elf $BUILT9)) {
        Fail "Meson-built libdxvk_d3d9.so is not ELF. This is the real corruption source."
    }

    if (!(Is-Elf $STAGED8)) {
        Log "REPAIR: staged D3D8 is not ELF -> restoring from Meson output."
        Copy-Item $BUILT8 $STAGED8 -Force
    }

    if (!(Is-Elf $STAGED9)) {
        Log "REPAIR: staged D3D9 is not ELF -> restoring from Meson output."
        Copy-Item $BUILT9 $STAGED9 -Force
    }

    if (!(Is-Elf $STAGED8) -or !(Is-Elf $STAGED9)) {
        Fail "Staged DXVK libraries are still not ELF after repair."
    }

    Log "STAGED D3D8/D3D9/SDL3: ELF VERIFIED"


    Step "3/7 REMOVE ONLY OUR EXPERIMENTAL DIRECT-DLOPEN PATCH IF PRESENT"

    if (Test-Path $WSI) {
        $wsiText = [IO.File]::ReadAllText($WSI)

        if ($wsiText.Contains("ZEROHOUR_ANDROID_SDL3_DLOPEN_BEGIN")) {
            if (Test-Path $WSI_BACKUP) {
                Copy-Item $WSI_BACKUP $WSI -Force
                Log "RESTORED SDL3 WSI from pre-experimental backup."
            }
            else {
                Log "WARNING: direct-dlopen marker exists but its backup is missing."
                Log "Leaving WSI source unchanged; this packaging repair does not rebuild DXVK."
            }
        }
        else {
            Log "NO EXPERIMENTAL DIRECT-DLOPEN PATCH PRESENT."
        }
    }


    Step "4/7 ENFORCE CORRECT JNI PACKAGING + CLEAN APK ONLY"

    $gradleText = [IO.File]::ReadAllText($BUILD_GRADLE)

    if ($gradleText -match 'useLegacyPackaging\s+true') {
        $gradleText = [regex]::Replace(
            $gradleText,
            'useLegacyPackaging\s+true',
            'useLegacyPackaging false'
        )

        [IO.File]::WriteAllText(
            $BUILD_GRADLE,
            $gradleText,
            (New-Object System.Text.UTF8Encoding($false))
        )

        Log "CHANGED: useLegacyPackaging true -> false"
    }
    elseif ($gradleText -match 'useLegacyPackaging\s*=\s*true') {
        $gradleText = [regex]::Replace(
            $gradleText,
            'useLegacyPackaging\s*=\s*true',
            'useLegacyPackaging = false'
        )

        [IO.File]::WriteAllText(
            $BUILD_GRADLE,
            $gradleText,
            (New-Object System.Text.UTF8Encoding($false))
        )

        Log "CHANGED: useLegacyPackaging = true -> false"
    }
    elseif ($gradleText -match 'useLegacyPackaging\s+false|useLegacyPackaging\s*=\s*false') {
        Log "useLegacyPackaging false: ALREADY CORRECT"
    }
    else {
        Fail "build.gradle has no useLegacyPackaging setting. Refusing to guess its block structure."
    }

    Log "CLEANING ONLY ANDROID PACKAGE OUTPUT..."

    $clean = Run-Native -Exe $GRADLE -ArgumentList @(
        "-p","$ROOT\android",
        "clean",
        "-PSAGE_SKIP_NATIVE_BUILD=true",
        "--no-daemon"
    )

    if ($clean.Code -ne 0) {
        Fail "Gradle clean failed."
    }

    $build = Run-Native -Exe $GRADLE -ArgumentList @(
        "-p","$ROOT\android",
        ":app:assembleDebug",
        "-PSAGE_SKIP_NATIVE_BUILD=true",
        "--no-daemon"
    )

    if ($build.Code -ne 0 -or !(Test-Path $APK)) {
        Fail "APK packaging failed."
    }

    Log "APK BUILT: $([math]::Round((Get-Item $APK).Length/1MB,2)) MB"


    Step "5/7 VERIFY APK .so ENTRIES ARE STORED + REAL ELF"

    $py = @'
import sys, zipfile, struct

apk = sys.argv[1]
targets = {
    "lib/arm64-v8a/libdxvk_d3d8.so",
    "lib/arm64-v8a/libdxvk_d3d9.so",
    "lib/arm64-v8a/libSDL3.so",
}

ok = True

with zipfile.ZipFile(apk, "r") as z:
    names = set(z.namelist())

    for name in sorted(targets):
        if name not in names:
            print(f"APK_MISSING {name}")
            ok = False
            continue

        info = z.getinfo(name)
        with z.open(name, "r") as f:
            magic = f.read(8)

        method = "STORED" if info.compress_type == zipfile.ZIP_STORED else f"COMPRESSED({info.compress_type})"
        print(f"APK_ENTRY {name} method={method} size={info.file_size} csize={info.compress_size} magic={magic.hex().upper()}")

        if not magic.startswith(b"\x7fELF"):
            print(f"APK_BAD_ELF {name}")
            ok = False

        if info.compress_type != zipfile.ZIP_STORED:
            print(f"APK_BAD_COMPRESSION {name}")
            ok = False

sys.exit(0 if ok else 17)
'@

    $pyFile = "$WORK\verify_apk_native_libs.py"
    [IO.File]::WriteAllText(
        $pyFile,
        $py,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $verify = Run-Native -Exe $PYTHON -ArgumentList @(
        $pyFile,$APK
    )

    if ($verify.Code -ne 0) {
        Fail "APK native library verification failed. The exact entry is shown above."
    }

    Log ""
    Log "ZIPALIGN 16K CHECK:"
    $za = Run-Native -Exe $ZIPALIGN -ArgumentList @(
        "-c","-P","16","-v","4",$APK
    )

    if ($za.Code -ne 0) {
        Fail "APK zipalign/page-alignment verification failed."
    }

    Log "APK NATIVE LIBRARIES: STORED + ELF + ALIGNED"


    Step "6/7 INSTALL UPDATE - PRESERVE GAMEDATA"

    $install = Run-Native -Exe $ADB -ArgumentList @(
        "install","-r","-d",$APK
    )

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "APK update failed. No uninstall was attempted."
    }

    Log "APK UPDATE: SUCCESS"
    Log "GAMEDATA: PRESERVED"


    Step "7/7 LAUNCH + CAPTURE NEXT REAL BLOCKER"

    Run-Native -Exe $ADB -ArgumentList @(
        "shell","am","force-stop","me.generalsx.zh"
    ) -Quiet | Out-Null

    Run-Native -Exe $ADB -ArgumentList @(
        "logcat","-c"
    ) -Quiet | Out-Null

    Run-Native -Exe $ADB -ArgumentList @(
        "shell","am","start","-n","me.generalsx.zh/.GameActivity"
    ) | Out-Null

    Start-Sleep -Seconds 15

    $gamePid = (& $ADB shell pidof me.generalsx.zh 2>$null | Out-String).Trim()
    $activityDump = (& $ADB shell dumpsys activity activities 2>$null | Out-String)
    $foreground = ($activityDump -match "mResumedActivity.*me\.generalsx\.zh")

    $stderrLines = & $ADB shell run-as me.generalsx.zh cat files/generals-stderr.log 2>&1
    $stderrText = ($stderrLines | Out-String)

    Log ""
    Log "----- ENGINE LAST 320 LINES -----"
    $stderrLines |
        Select-Object -Last 320 |
        ForEach-Object { Log $_.ToString() }

    Log ""
    Log "----- RELEVANT LOGCAT -----"
    $logcat = & $ADB logcat -d -v time 2>&1

    $logcat |
        Select-String -Pattern "bad ELF magic|504b0304|SDL3|dxvk_d3d9|dxvk_d3d8|linker|dlopen|Vulkan|robustness2|Mali|AndroidRuntime|FATAL" |
        Select-Object -Last 450 |
        ForEach-Object { Log $_.Line }

    $relevant = ($logcat | Out-String)

    Log ""
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($relevant -match "bad ELF magic|504b0304") {
        Fail "Bad ELF/ZIP-magic is STILL present after verified APK packaging. Exact linker line is above."
    }

    Log ""
    Log "BAD ELF / ZIP-MAGIC BLOCKER: GONE"

    if ($stderrText -match "SDL3 WSI: Failed to load SDL3 DLL") {
        Fail "Native-library packaging is fixed. SDL3 loader still fails for a separate reason."
    }

    if ($stderrText -match "VK_EXT_robustness2") {
        Fail "Native-library packaging and SDL3 advanced. Next blocker is Mali VK_EXT_robustness2."
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "Native-library packaging advanced. Vulkan device creation is now the blocker."
    }

    if ($gamePid -and $foreground) {
        Log ""
        Log "SUCCESS: ZERO HOUR IS ALIVE IN FOREGROUND."
        Log "LOOK AT THE PHONE NOW."
        exit 0
    }

    Fail "Bad-ELF blocker is gone, but the app is not the resumed foreground activity. Exact end is above."
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" |
        Out-File $LOG -Append -Encoding utf8

    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
