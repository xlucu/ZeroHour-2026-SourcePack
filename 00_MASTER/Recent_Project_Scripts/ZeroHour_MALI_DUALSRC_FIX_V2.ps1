$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - MALI DUALSRC FIX V2
#
# Exact current source:
#   ENABLE_FEATURE(core.features, dualSrcBlend, true),
#
# This version patches ONLY Android:
#
#   #if defined(__ANDROID__)
#     ENABLE_FEATURE(... dualSrcBlend, false),
#   #else
#     ENABLE_FEATURE(... dualSrcBlend, true),
#   #endif
#
# Then:
# - incremental DXVK rebuild only
# - keeps the proven SDL3 Android direct-dlopen path
# - packages APK
# - verifies ELF + uncompressed JNI libs
# - installs as update
# - launches and captures the NEXT missing Mali feature/extension
#
# NO libmain.so rebuild.
# NO GameData recopy.
# NO uninstall.
#
# ONE LOG:
#   C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$WORK = "$ROOT\tools\mali-dxvk"
$DXVKSRC = "$WORK\actual-dxvk-source"
$DXVKBUILD = "$WORK\build-android-real"

$SDK = "$env:LOCALAPPDATA\Android\Sdk"
$ADB = "$SDK\platform-tools\adb.exe"
$ZIPALIGN = "$SDK\build-tools\35.0.0\zipalign.exe"

$JBR = "C:\Program Files\Android\Android Studio\jbr"
$MESON = "C:\Users\DELL\AppData\Roaming\Python\Python314\Scripts\meson.exe"
$GLSLANG = "$WORK\glslang-main-tot\bin\glslang.exe"
$PYTHON = "C:\Users\DELL\AppData\Local\Programs\Python\Python314\python.exe"

$DEVICEINFO = "$DXVKSRC\src\dxvk\dxvk_device_info.cpp"
$WSI = "$DXVKSRC\src\wsi\sdl3\wsi_platform_sdl3.cpp"

$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$D3D8_DST = "$JNI\libdxvk_d3d8.so"
$D3D9_DST = "$JNI\libdxvk_d3d9.so"
$SDL3_DST = "$JNI\libSDL3.so"

$GRADLE = "$ROOT\tools\gradle-8.7\bin\gradle.bat"
$BUILD_GRADLE = "$ROOT\android\app\build.gradle"
$APK = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"

$LOG = "$env:USERPROFILE\Desktop\ZeroHour_MALI_LOG.txt"

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

    [pscustomobject]@{
        Code = $code
        Text = ($lines -join "`r`n")
    }
}

function Get-Magic([string]$Path) {
    if (!(Test-Path $Path)) { return "MISSING" }

    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 4
        $n = $fs.Read($buf,0,4)
    }
    finally {
        $fs.Dispose()
    }

    if ($n -ne 4) { return "SHORT" }
    (($buf | ForEach-Object { $_.ToString("X2") }) -join "")
}

try {
    Step "1/7 VERIFY CURRENT READY STATE"

    foreach ($p in @(
        $ROOT,$WORK,$DXVKSRC,$DXVKBUILD,$DEVICEINFO,$WSI,
        $ADB,$ZIPALIGN,$JBR,$MESON,$GLSLANG,$PYTHON,
        $JNI,$D3D8_DST,$D3D9_DST,$SDL3_DST,
        $GRADLE,$BUILD_GRADLE
    )) {
        if (!(Test-Path $p)) {
            Fail "Missing required path: $p"
        }
    }

    $env:JAVA_HOME = $JBR
    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:Path = "$(Split-Path $GLSLANG -Parent);$JBR\bin;$SDK\platform-tools;$SDK\cmake\3.31.6\bin;$SDK\build-tools\35.0.0;C:\Program Files\Git\usr\bin;C:\Program Files\Git\cmd;$(Split-Path $MESON -Parent);$(Split-Path $PYTHON -Parent);$env:Path"

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
    Log "D3D8 MAGIC: $(Get-Magic $D3D8_DST)"
    Log "D3D9 MAGIC: $(Get-Magic $D3D9_DST)"
    Log "SDL3 MAGIC: $(Get-Magic $SDL3_DST)"
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"


    Step "2/7 VERIFY THE PROVEN ANDROID SDL3 PATH"

    $wsiText = [IO.File]::ReadAllText($WSI)

    if ($wsiText.Contains("ZEROHOUR_ANDROID_SDL3_DLOPEN_BEGIN")) {
        Log "ANDROID SDL3 DIRECT-DLOPEN PATCH: PRESENT"
    }
    else {
        Fail "The proven Android SDL3 direct-dlopen patch is not present. Refusing to rebuild a regressed DXVK."
    }


    Step "3/7 PATCH dualSrcBlend REQUIREMENT - ANDROID ONLY"

    $text = [IO.File]::ReadAllText($DEVICEINFO)

    $oldLine = "ENABLE_FEATURE(core.features, dualSrcBlend, true),"
    $marker = "ZEROHOUR_ANDROID_MALI_DUALSRC_OPTIONAL"

    if ($text.Contains($marker)) {
        Log "dualSrcBlend ANDROID PATCH: ALREADY PRESENT"
        (Get-Item $DEVICEINFO).LastWriteTime = Get-Date
    }
    else {
        $count = ([regex]::Matches(
            $text,
            [regex]::Escape($oldLine)
        )).Count

        Log "EXACT dualSrcBlend REQUIRED LINE COUNT: $count"

        if ($count -ne 1) {
            Log ""
            Log "Nearby source:"
            $lines = Get-Content $DEVICEINFO
            for ($i=0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "dualSrcBlend") {
                    $lo = [Math]::Max(0,$i-8)
                    $hi = [Math]::Min($lines.Count-1,$i+8)
                    for ($j=$lo; $j -le $hi; $j++) {
                        Log ("{0}: {1}" -f ($j+1),$lines[$j])
                    }
                }
            }

            Fail "Expected exactly one required dualSrcBlend line."
        }

        $replacement = @"
#if defined(__ANDROID__)
      // ZEROHOUR_ANDROID_MALI_DUALSRC_OPTIONAL
      ENABLE_FEATURE(core.features, dualSrcBlend, false),
#else
      ENABLE_FEATURE(core.features, dualSrcBlend, true),
#endif
"@

        $patched = $text.Replace($oldLine,$replacement)

        $backup = "$DEVICEINFO.before_zh_android_dualsrc.bak"
        if (!(Test-Path $backup)) {
            Copy-Item $DEVICEINFO $backup -Force
            Log "BACKUP CREATED:"
            Log $backup
        }

        [IO.File]::WriteAllText(
            $DEVICEINFO,
            $patched,
            (New-Object System.Text.UTF8Encoding($false))
        )

        Log "dualSrcBlend ANDROID PATCH: APPLIED"
    }

    $verifyText = [IO.File]::ReadAllText($DEVICEINFO)

    if (!$verifyText.Contains($marker)) {
        Fail "dualSrcBlend patch verification failed."
    }

    Log "PATCH VERIFICATION: PASSED"


    Step "4/7 INCREMENTAL DXVK REBUILD ONLY"

    $compile = Run-Native -Exe $MESON -ArgumentList @(
        "compile","-C",$DXVKBUILD
    )

    if ($compile.Code -ne 0) {
        Fail "DXVK incremental rebuild failed."
    }

    $built8 = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)^libdxvk_d3d8\.so(?:\..*)?$' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    $built9 = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)^libdxvk_d3d9\.so(?:\..*)?$' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (!$built8 -or !$built9) {
        Fail "DXVK rebuilt but D3D8/D3D9 outputs were not found."
    }

    if ((Get-Magic $built8.FullName) -ne "7F454C46") {
        Fail "Built D3D8 is not ELF."
    }

    if ((Get-Magic $built9.FullName) -ne "7F454C46") {
        Fail "Built D3D9 is not ELF."
    }

    Log "DXVK REBUILD: SUCCESS"
    Log "D3D8: $($built8.FullName)"
    Log "D3D9: $($built9.FullName)"


    Step "5/7 STAGE + CLEAN PACKAGE + VERIFY APK"

    Copy-Item $built8.FullName $D3D8_DST -Force
    Copy-Item $built9.FullName $D3D9_DST -Force

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
    }

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

    $verifyPy = @'
import sys, zipfile

apk = sys.argv[1]
targets = [
    "lib/arm64-v8a/libdxvk_d3d8.so",
    "lib/arm64-v8a/libdxvk_d3d9.so",
    "lib/arm64-v8a/libSDL3.so",
]

ok = True

with zipfile.ZipFile(apk, "r") as z:
    for name in targets:
        if name not in z.namelist():
            print("APK_MISSING", name)
            ok = False
            continue

        info = z.getinfo(name)
        with z.open(name) as f:
            magic = f.read(4)

        print(
            "APK_ENTRY",
            name,
            "method=", info.compress_type,
            "magic=", magic.hex().upper(),
            "size=", info.file_size
        )

        if magic != b"\x7fELF":
            ok = False

        if info.compress_type != zipfile.ZIP_STORED:
            ok = False

sys.exit(0 if ok else 19)
'@

    $verifyFile = "$WORK\verify_apk_dualsrc_v2.py"
    [IO.File]::WriteAllText(
        $verifyFile,
        $verifyPy,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $verify = Run-Native -Exe $PYTHON -ArgumentList @(
        $verifyFile,$APK
    )

    if ($verify.Code -ne 0) {
        Fail "APK native library verification failed."
    }

    $za = Run-Native -Exe $ZIPALIGN -ArgumentList @(
        "-c","-P","16","-v","4",$APK
    )

    if ($za.Code -ne 0) {
        Fail "APK 16K alignment verification failed."
    }

    Log "APK VERIFIED: ELF + STORED + ALIGNED"
    Log "APK SIZE: $([math]::Round((Get-Item $APK).Length/1MB,2)) MB"


    Step "6/7 INSTALL UPDATE - PRESERVE GAMEDATA"

    $install = Run-Native -Exe $ADB -ArgumentList @(
        "install","-r","-d",$APK
    )

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "APK update install failed."
    }

    Log "APK UPDATE: SUCCESS"
    Log "GAMEDATA: PRESERVED"


    Step "7/7 LAUNCH + REPORT THE NEXT REAL MALI GATE"

    Run-Native -Exe $ADB -ArgumentList @(
        "shell","am","force-stop","me.generalsx.zh"
    ) -Quiet | Out-Null

    Run-Native -Exe $ADB -ArgumentList @(
        "logcat","-c"
    ) -Quiet | Out-Null

    Run-Native -Exe $ADB -ArgumentList @(
        "shell","am","start","-n","me.generalsx.zh/.GameActivity"
    ) | Out-Null

    Start-Sleep -Seconds 18

    $gamePid = (& $ADB shell pidof me.generalsx.zh 2>$null | Out-String).Trim()

    $activityDump = (& $ADB shell dumpsys activity activities 2>$null | Out-String)
    $foreground = ($activityDump -match "mResumedActivity.*me\.generalsx\.zh")

    $stderrLines = & $ADB shell run-as me.generalsx.zh cat files/generals-stderr.log 2>&1
    $stderrText = ($stderrLines | Out-String)

    Log ""
    Log "----- ENGINE LAST 440 LINES -----"
    $stderrLines |
        Select-Object -Last 440 |
        ForEach-Object { Log $_.ToString() }

    Log ""
    Log "----- RELEVANT LOGCAT -----"
    $logcat = & $ADB logcat -d -v time 2>&1

    $logcat |
        Select-String -Pattern "dualSrcBlend|Skipping: Device|Required Vulkan|robustness2|nullDescriptor|No adapters|DxvkAdapter|DXVK|Vulkan|Mali|SDL3|bad ELF|FATAL|AndroidRuntime" |
        Select-Object -Last 550 |
        ForEach-Object { Log $_.Line }

    Log ""
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($stderrText -match "required feature 'dualSrcBlend'") {
        Fail "dualSrcBlend is STILL required. Another code path is enforcing it."
    }

    Log ""
    Log "dualSrcBlend ADAPTER GATE: GONE"

    if ($stderrText -match "Skipping: Device does not support required feature '([^']+)'") {
        $feature = $Matches[1]
        Fail "Next missing required Vulkan feature: $feature"
    }

    if ($stderrText -match "Required Vulkan extension ([A-Za-z0-9_]+) not supported") {
        $ext = $Matches[1]
        Fail "Next missing required Vulkan extension: $ext"
    }

    if ($stderrText -match "VK_EXT_robustness2|robustBufferAccess2|nullDescriptor") {
        Fail "Next confirmed Mali blocker is robustness2/nullDescriptor handling."
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "Adapter passed farther, but Vulkan device creation failed. Exact cause is above."
    }

    if ($gamePid -and $foreground) {
        Log ""
        Log "SUCCESS: ZERO HOUR IS ALIVE IN FOREGROUND."
        Log "LOOK AT THE PHONE NOW."
        exit 0
    }

    Fail "dualSrcBlend is cleared, but Zero Hour is not the resumed foreground activity. Exact end is above."
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" |
        Out-File $LOG -Append -Encoding utf8

    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
