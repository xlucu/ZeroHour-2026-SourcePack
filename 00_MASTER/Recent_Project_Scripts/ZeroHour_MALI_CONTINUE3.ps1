$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - MALI CONTINUE 3
#
# Continues from the exact current state.
# Fixes the current Meson error:
#   Missing SPIRV-Headers
#
# It first initializes DXVK's own submodules. If the SPIR-V
# header is still missing, it clones the official Khronos
# SPIRV-Headers directly into DXVK's expected include/spirv path.
#
# It does NOT:
# - clone the full Android port again
# - rebuild libmain.so
# - recopy GameData
#
# ONE LOG ONLY:
# C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt
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

$PKGSHIM = "$ROOT\tools\pkg-config-sdl3.py"
$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$GRADLE = "$ROOT\tools\gradle-8.7\bin\gradle.bat"
$APK = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"

$DXVKBUILD = "$WORK\build-android-real"
$CROSS = "$WORK\meson-android-arm64-real.txt"

$GLSLANG = "$WORK\glslang-main-tot\bin\glslang.exe"
$SPIRV_DIR = "$DXVKSRC\include\spirv"
$SPIRV_HPP = "$SPIRV_DIR\include\spirv\unified1\spirv.hpp"

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
    Step "1/6 VERIFY CURRENT READY STATE"

    foreach ($p in @(
        $ROOT,$WORK,$DXVKSRC,$ADB,$NDK,$JBR,
        $PYTHON,$MESON,$PKGSHIM,$JNI,$GRADLE,$GLSLANG
    )) {
        if (!(Test-Path $p)) {
            Fail "Missing required path: $p"
        }
    }

    if (!(Test-Path "$DXVKSRC\meson.build")) {
        Fail "DXVK meson.build is missing."
    }

    if (!(Test-Path "$DXVKSRC\src\d3d8") -or !(Test-Path "$DXVKSRC\src\d3d9")) {
        Fail "DXVK D3D8/D3D9 source directories are missing."
    }

    $env:JAVA_HOME = $JBR
    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:ANDROID_NDK_HOME = $NDK
    $env:Path = "$(Split-Path $GLSLANG -Parent);$JBR\bin;$SDK\platform-tools;$SDK\cmake\3.31.6\bin;C:\Program Files\Git\cmd;$(Split-Path $MESON -Parent);$(Split-Path $PYTHON -Parent);$env:Path"

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
    Log "DXVK SOURCE: $DXVKSRC"
    Log "GLSLANG: $GLSLANG"
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"


    Step "2/6 POPULATE DXVK DEPENDENCIES"

    Log "Initializing DXVK submodules recursively..."

    $sync = Run-Native -Exe "git.exe" -ArgumentList @(
        "-C",$DXVKSRC,
        "submodule","sync","--recursive"
    )

    $sub = Run-Native -Exe "git.exe" -ArgumentList @(
        "-C",$DXVKSRC,
        "submodule","update","--init","--recursive"
    )

    Log "SUBMODULE UPDATE EXIT CODE: $($sub.Code)"

    if (!(Test-Path $SPIRV_HPP)) {
        Log ""
        Log "SPIRV header is still missing after submodule update."
        Log "Installing official Khronos SPIRV-Headers into DXVK include/spirv..."

        if (Test-Path $SPIRV_DIR) {
            $isRepo = Run-Native -Exe "git.exe" -ArgumentList @(
                "-C",$SPIRV_DIR,
                "rev-parse","--is-inside-work-tree"
            ) -Quiet

            if ($isRepo.Code -ne 0) {
                Remove-Item $SPIRV_DIR -Recurse -Force
            }
        }

        if (!(Test-Path "$SPIRV_DIR\.git")) {
            if (Test-Path $SPIRV_DIR) {
                Remove-Item $SPIRV_DIR -Recurse -Force
            }

            $cloneSpv = Run-Native -Exe "git.exe" -ArgumentList @(
                "clone","--depth","1",
                "https://github.com/KhronosGroup/SPIRV-Headers.git",
                $SPIRV_DIR
            )

            if ($cloneSpv.Code -ne 0) {
                Fail "Could not clone official Khronos SPIRV-Headers."
            }
        }
    }

    if (!(Test-Path $SPIRV_HPP)) {
        Fail "spirv/unified1/spirv.hpp is still missing after dependency repair."
    }

    Log "SPIRV-HEADERS: READY"
    Log $SPIRV_HPP

    # Show other populated DXVK include dependencies so the next Meson
    # failure, if any, is immediately meaningful.
    foreach ($dep in @(
        "$DXVKSRC\include\vulkan",
        "$DXVKSRC\include\native\directx",
        "$DXVKSRC\include\spirv"
    )) {
        if (Test-Path $dep) {
            Log "DEPENDENCY READY: $dep"
        } else {
            Log "DEPENDENCY NOT PRESENT: $dep"
        }
    }


    Step "3/6 RECONFIGURE + BUILD DXVK ONLY"

    $gt = Run-Native -Exe $GLSLANG -ArgumentList @("--version")
    if ($gt.Code -ne 0) {
        Fail "glslang exists but cannot execute."
    }

    $clang   = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android28-clang.cmd"
    $clangpp = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android28-clang++.cmd"
    $ar      = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-ar.exe"
    $strip   = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe"

    foreach ($p in @($clang,$clangpp,$ar,$strip)) {
        if (!(Test-Path $p)) {
            Fail "Missing NDK compiler tool: $p"
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

    Push-Location $DXVKSRC
    try {
        $setup = Run-Native -Exe $MESON -ArgumentList @(
            "setup",
            $DXVKBUILD,
            "--cross-file",$CROSS,
            "-Dbuildtype=release"
        )

        if ($setup.Code -ne 0) {
            Fail "Meson setup failed after SPIRV-Headers repair."
        }
    }
    finally {
        Pop-Location
    }

    $compile = Run-Native -Exe $MESON -ArgumentList @(
        "compile","-C",$DXVKBUILD
    )

    if ($compile.Code -ne 0) {
        Fail "DXVK compile failed."
    }

    # Android forks do not all use the exact same filename, so accept
    # either libdxvk_d3d8.so or another d3d8 .so and normalize it later.
    $d3d8 = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match "(?i)d3d8.*\.so$"
        } |
        Sort-Object @{
            Expression = {
                if ($_.Name -eq "libdxvk_d3d8.so") { 0 } else { 1 }
            }
        }, Length -Descending |
        Select-Object -First 1

    $d3d9 = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match "(?i)d3d9.*\.so$"
        } |
        Sort-Object @{
            Expression = {
                if ($_.Name -eq "libdxvk_d3d9.so") { 0 } else { 1 }
            }
        }, Length -Descending |
        Select-Object -First 1

    if (!$d3d8 -or !$d3d9) {
        Fail "DXVK compiled but Android d3d8/d3d9 shared libraries were not found."
    }

    Log "DXVK BUILD SUCCESS"
    Log "D3D8 OUTPUT: $($d3d8.FullName)"
    Log "D3D9 OUTPUT: $($d3d9.FullName)"


    Step "4/6 REPLACE ONLY DXVK + PACKAGE APK"

    $dest8 = Join-Path $JNI "libdxvk_d3d8.so"
    $dest9 = Join-Path $JNI "libdxvk_d3d9.so"

    if (!(Test-Path $dest8) -or !(Test-Path $dest9)) {
        Fail "Current packaged DXVK libraries are missing."
    }

    if (!(Test-Path "$dest8.before_mali.bak")) {
        Copy-Item $dest8 "$dest8.before_mali.bak" -Force
    }

    if (!(Test-Path "$dest9.before_mali.bak")) {
        Copy-Item $dest9 "$dest9.before_mali.bak" -Force
    }

    Copy-Item $d3d8.FullName $dest8 -Force
    Copy-Item $d3d9.FullName $dest9 -Force

    Log "DXVK SWAPPED"
    Log "ENGINE UNCHANGED"
    Log "GAMEDATA UNCHANGED"

    $sdkEscaped = $SDK.Replace("\","\\").Replace(":","\:")
    "sdk.dir=$sdkEscaped" | Out-File "$ROOT\android\local.properties" -Encoding ascii

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $gradleOutput = & $GRADLE `
            -p "$ROOT\android" `
            :app:assembleDebug `
            -PSAGE_SKIP_NATIVE_BUILD=true `
            --no-daemon `
            2>&1

        $gradleCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPref
    }

    foreach ($line in @($gradleOutput)) {
        if ($null -ne $line) {
            Log $line.ToString()
        }
    }

    if ($gradleCode -ne 0 -or !(Test-Path $APK)) {
        Fail "APK packaging failed."
    }

    Log "APK READY: $([math]::Round((Get-Item $APK).Length/1MB,2)) MB"


    Step "5/6 INSTALL UPDATE WITHOUT DELETING GAMEDATA"

    $install = Run-Native -Exe $ADB -ArgumentList @(
        "install","-r","-d",$APK
    )

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "APK update failed. No uninstall was attempted, so existing GameData was preserved."
    }

    Log "APK UPDATED"
    Log "NO GAMEDATA RECOPY"


    Step "6/6 LAUNCH + CHECK THE REAL GRAPHICS RESULT"

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
    Log "----- ENGINE LAST 260 LINES -----"

    $stderrLines |
        Select-Object -Last 260 |
        ForEach-Object { Log $_.ToString() }

    Log ""
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($stderrText -match "Required Vulkan extension VK_EXT_robustness2 not supported") {
        Fail "The newly built DXVK still hard-requires VK_EXT_robustness2."
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "DXVK device creation still failed. The exact new reason is in this log."
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
