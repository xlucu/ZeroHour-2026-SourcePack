$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - MALI CONTINUE 4
#
# Current blocker:
#   meson.build:142: ERROR: Program 'touch' not found
#
# This resumes from the existing DXVK source + submodules.
# It does NOT rebuild libmain.so and does NOT recopy GameData.
#
# ONE LOG:
#   C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$WORK = "$ROOT\tools\mali-dxvk"
$DXVKSRC = "$WORK\actual-dxvk-source"

$SDK = "$env:LOCALAPPDATA\Android\Sdk"
$NDK = "$SDK\ndk\27.1.12297006"
$JBR = "C:\Program Files\Android\Android Studio\jbr"
$ADB = "$SDK\platform-tools\adb.exe"

$PYTHON = "C:\Users\DELL\AppData\Local\Programs\Python\Python314\python.exe"
$MESON = "C:\Users\DELL\AppData\Roaming\Python\Python314\Scripts\meson.exe"

$GLSLANG = "$WORK\glslang-main-tot\bin\glslang.exe"
$PKGSHIM = "$ROOT\tools\pkg-config-sdl3.py"

$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$GRADLE = "$ROOT\tools\gradle-8.7\bin\gradle.bat"
$APK = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"

$DXVKBUILD = "$WORK\build-android-real"
$CROSS = "$WORK\meson-android-arm64-real.txt"

$TOUCH_DIR = "$WORK\host-tools"
$TOUCH_CMD = "$TOUCH_DIR\touch.cmd"

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

try {
    Step "1/6 VERIFY READY STATE"

    foreach ($p in @(
        $ROOT,$WORK,$DXVKSRC,$ADB,$NDK,$JBR,
        $PYTHON,$MESON,$GLSLANG,$PKGSHIM,$JNI,$GRADLE
    )) {
        if (!(Test-Path $p)) {
            Fail "Missing required path: $p"
        }
    }

    if (!(Test-Path "$DXVKSRC\include\spirv\include\spirv\unified1\spirv.hpp")) {
        Fail "SPIRV-Headers are no longer present."
    }

    if (!(Test-Path "$DXVKSRC\include\vulkan")) {
        Fail "Vulkan-Headers are missing."
    }

    $env:JAVA_HOME = $JBR
    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:ANDROID_NDK_HOME = $NDK

    Log "DEVICE CHECK..."

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
    Log "SPIRV-HEADERS: READY"
    Log "VULKAN-HEADERS: READY"
    Log "GLSLANG: READY"
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"


    Step "2/6 PROVIDE WINDOWS 'touch' FOR MESON"

    New-Item $TOUCH_DIR -ItemType Directory -Force | Out-Null

    $gitTouch = "C:\Program Files\Git\usr\bin\touch.exe"

    if (Test-Path $gitTouch) {
        Log "FOUND GIT TOUCH:"
        Log $gitTouch

        # Make a stable wrapper so Meson does not depend on Git's PATH layout.
        $cmdText = '@echo off' + "`r`n" +
                   '"' + $gitTouch + '" %*' + "`r`n"

        [IO.File]::WriteAllText(
            $TOUCH_CMD,
            $cmdText,
            [Text.Encoding]::ASCII
        )
    }
    else {
        Log "Git touch.exe not found. Creating a tiny Python-compatible touch shim."

        $touchPy = "$TOUCH_DIR\touch.py"

        $pyText = @'
import os
import sys
import time

for arg in sys.argv[1:]:
    if arg.startswith("-"):
        continue
    parent = os.path.dirname(os.path.abspath(arg))
    if parent:
        os.makedirs(parent, exist_ok=True)
    if os.path.exists(arg):
        os.utime(arg, None)
    else:
        with open(arg, "ab"):
            pass
'@

        [IO.File]::WriteAllText(
            $touchPy,
            $pyText,
            (New-Object System.Text.UTF8Encoding($false))
        )

        $cmdText = '@echo off' + "`r`n" +
                   '"' + $PYTHON + '" "' + $touchPy + '" %*' + "`r`n"

        [IO.File]::WriteAllText(
            $TOUCH_CMD,
            $cmdText,
            [Text.Encoding]::ASCII
        )
    }

    $env:Path = "$TOUCH_DIR;C:\Program Files\Git\usr\bin;$(Split-Path $GLSLANG -Parent);$JBR\bin;$SDK\platform-tools;$SDK\cmake\3.31.6\bin;C:\Program Files\Git\cmd;$(Split-Path $MESON -Parent);$(Split-Path $PYTHON -Parent);$env:Path"

    $touchFound = Get-Command touch -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source

    if (!$touchFound) {
        Fail "touch is still not visible on PATH."
    }

    Log "TOUCH READY:"
    Log $touchFound

    # Functional proof: touch a disposable file.
    $touchTest = "$TOUCH_DIR\touch-test.tmp"
    if (Test-Path $touchTest) { Remove-Item $touchTest -Force }

    & touch $touchTest

    if (!(Test-Path $touchTest)) {
        Fail "touch was found but did not create a file."
    }

    Remove-Item $touchTest -Force
    Log "TOUCH FUNCTION TEST: PASSED"


    Step "3/6 RECONFIGURE + BUILD DXVK ONLY"

    $clang   = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android28-clang.cmd"
    $clangpp = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android28-clang++.cmd"
    $ar      = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-ar.exe"
    $strip   = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe"

    foreach ($p in @($clang,$clangpp,$ar,$strip)) {
        if (!(Test-Path $p)) {
            Fail "Missing NDK tool: $p"
        }
    }

    $crossText = @"
[binaries]
c = '$($clang.Replace("\","/"))'
cpp = '$($clangpp.Replace("\","/"))'
ar = '$($ar.Replace("\","/"))'
strip = '$($strip.Replace("\","/"))'
pkg-config = ['$($PYTHON.Replace("\","/"))', '$($PKGSHIM.Replace("\","/"))']

[built-in options]
c_args = ['-DVK_ENABLE_BETA_EXTENSIONS', '-DVK_USE_PLATFORM_ANDROID_KHR']
cpp_args = ['-DVK_ENABLE_BETA_EXTENSIONS', '-DVK_USE_PLATFORM_ANDROID_KHR']

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
"@

    [IO.File]::WriteAllText(
        $CROSS,
        $crossText,
        (New-Object System.Text.UTF8Encoding($false))
    )

    if (Test-Path $DXVKBUILD) {
        Remove-Item $DXVKBUILD -Recurse -Force
    }

    $mesonArgs = @(
        "setup",
        $DXVKBUILD,
        "--cross-file",$CROSS,
        "-Dbuildtype=release"
    )

    # DXVK Native requires a WSI backend. Detect the option name from
    # this exact fork instead of assuming it.
    $optionFiles = @(
        "$DXVKSRC\meson.options",
        "$DXVKSRC\meson_options.txt"
    ) | Where-Object { Test-Path $_ }

    $optionText = ""
    foreach ($of in $optionFiles) {
        $optionText += [IO.File]::ReadAllText($of) + "`n"
    }

    if ($optionText -match "dxvk_native_wsi") {
        $mesonArgs += "-Ddxvk_native_wsi=sdl3"
        Log "DXVK WSI OPTION: dxvk_native_wsi=sdl3"
    }
    elseif ($optionText -match "dxvk_wsi") {
        $mesonArgs += "-Ddxvk_wsi=sdl3"
        Log "DXVK WSI OPTION: dxvk_wsi=sdl3"
    }
    else {
        Log "DXVK WSI OPTION: using fork default/autodetection"
    }

    Push-Location $DXVKSRC
    try {
        $setup = Run-Native -Exe $MESON -ArgumentList $mesonArgs
        if ($setup.Code -ne 0) {
            Fail "Meson setup failed after touch fix."
        }
    }
    finally {
        Pop-Location
    }

    Log ""
    Log "MESON SETUP: SUCCESS"
    Log "COMPILING DXVK..."

    $compile = Run-Native -Exe $MESON -ArgumentList @(
        "compile","-C",$DXVKBUILD
    )

    if ($compile.Code -ne 0) {
        Fail "DXVK compile failed."
    }

    $d3d8 = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "(?i)d3d8.*\.so$" } |
        Sort-Object Length -Descending |
        Select-Object -First 1

    $d3d9 = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "(?i)d3d9.*\.so$" } |
        Sort-Object Length -Descending |
        Select-Object -First 1

    if (!$d3d8 -or !$d3d9) {
        Log "Shared objects found in build tree:"
        Get-ChildItem $DXVKBUILD -Recurse -File -Filter "*.so" -ErrorAction SilentlyContinue |
            ForEach-Object { Log $_.FullName }

        Fail "DXVK compiled but d3d8/d3d9 Android .so outputs were not found."
    }

    Log ""
    Log "DXVK BUILD SUCCESS"
    Log "D3D8: $($d3d8.FullName)"
    Log "D3D9: $($d3d9.FullName)"


    Step "4/6 SWAP ONLY DXVK + PACKAGE APK"

    $dest8 = Join-Path $JNI "libdxvk_d3d8.so"
    $dest9 = Join-Path $JNI "libdxvk_d3d9.so"

    if (!(Test-Path $dest8) -or !(Test-Path $dest9)) {
        Fail "Current packaged DXVK runtime is missing."
    }

    if (!(Test-Path "$dest8.before_mali.bak")) {
        Copy-Item $dest8 "$dest8.before_mali.bak" -Force
    }

    if (!(Test-Path "$dest9.before_mali.bak")) {
        Copy-Item $dest9 "$dest9.before_mali.bak" -Force
    }

    Copy-Item $d3d8.FullName $dest8 -Force
    Copy-Item $d3d9.FullName $dest9 -Force

    Log "DXVK REPLACED"
    Log "libmain.so UNCHANGED"
    Log "GameData UNCHANGED"

    $sdkEscaped = $SDK.Replace("\","\\").Replace(":","\:")
    "sdk.dir=$sdkEscaped" | Out-File "$ROOT\android\local.properties" -Encoding ascii

    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $gradleOut = & $GRADLE `
            -p "$ROOT\android" `
            :app:assembleDebug `
            -PSAGE_SKIP_NATIVE_BUILD=true `
            --no-daemon `
            2>&1

        $gradleCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
    }

    foreach ($line in @($gradleOut)) {
        if ($null -ne $line) { Log $line.ToString() }
    }

    if ($gradleCode -ne 0 -or !(Test-Path $APK)) {
        Fail "APK packaging failed."
    }

    Log "APK READY: $([math]::Round((Get-Item $APK).Length/1MB,2)) MB"


    Step "5/6 INSTALL UPDATE - PRESERVE ALL GAME DATA"

    $install = Run-Native -Exe $ADB -ArgumentList @(
        "install","-r","-d",$APK
    )

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "APK update failed. No uninstall was attempted, so GameData remains preserved."
    }

    Log "APK UPDATE: SUCCESS"
    Log "NO 2GB RECOPY"


    Step "6/6 LAUNCH + VERIFY REAL FOREGROUND GAME"

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
    Log "----- ENGINE LAST 280 LINES -----"

    $stderrLines |
        Select-Object -Last 280 |
        ForEach-Object { Log $_.ToString() }

    Log ""
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($stderrText -match "Required Vulkan extension VK_EXT_robustness2 not supported") {
        Fail "The new DXVK still hard-requires VK_EXT_robustness2."
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "DXVK device creation failed. The exact new reason is printed above."
    }

    if ($gamePid -and $foreground) {
        Log ""
        Log "SUCCESS: ZERO HOUR IS ALIVE IN THE FOREGROUND."
        Log "LOOK AT THE PHONE NOW."
        exit 0
    }

    Fail "Zero Hour is not the resumed foreground activity after 15 seconds."
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" |
        Out-File $LOG -Append -Encoding utf8

    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
