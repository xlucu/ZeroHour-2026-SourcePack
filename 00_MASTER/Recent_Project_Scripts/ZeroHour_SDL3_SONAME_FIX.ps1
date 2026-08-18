$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - SDL3 SONAME + DLOPEN FIX
#
# Does:
#   1) Reads the REAL DT_SONAME from packaged libSDL3.so
#   2) Makes DXVK request that exact soname
#   3) Adds Android dlerror() logging to DXVK's SDL3 loader
#   4) Incrementally rebuilds DXVK only
#   5) Packages + installs as update (GameData preserved)
#   6) Launches and captures the next real blocker
#
# Does NOT:
#   - rebuild libmain.so
#   - recopy GameData
#   - uninstall the app
#
# ONE LOG:
#   C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$WORK = "$ROOT\tools\mali-dxvk"
$DXVKSRC = "$WORK\actual-dxvk-source"
$DXVKBUILD = "$WORK\build-android-real"

$SDK = "$env:LOCALAPPDATA\Android\Sdk"
$NDK = "$SDK\ndk\27.1.12297006"
$ADB = "$SDK\platform-tools\adb.exe"
$READELF = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe"

$JBR = "C:\Program Files\Android\Android Studio\jbr"
$MESON = "C:\Users\DELL\AppData\Roaming\Python\Python314\Scripts\meson.exe"
$GLSLANG = "$WORK\glslang-main-tot\bin\glslang.exe"

$WSI = "$DXVKSRC\src\wsi\sdl3\wsi_platform_sdl3.cpp"

$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$SDL3 = "$JNI\libSDL3.so"
$D3D8_DST = "$JNI\libdxvk_d3d8.so"
$D3D9_DST = "$JNI\libdxvk_d3d9.so"

$GRADLE = "$ROOT\tools\gradle-8.7\bin\gradle.bat"
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

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $out = & $Exe @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPref
    }

    $lines = @()
    foreach ($item in @($out)) {
        if ($null -ne $item) {
            $s = $item.ToString()
            $lines += $s
            if (!$Quiet) { Log $s }
        }
    }

    return [pscustomobject]@{
        Code = $code
        Text = ($lines -join "`r`n")
    }
}

try {
    Step "1/6 VERIFY CURRENT STATE"

    foreach ($p in @(
        $ROOT,$WORK,$DXVKSRC,$DXVKBUILD,$WSI,
        $ADB,$READELF,$MESON,$GLSLANG,$SDL3,
        $D3D8_DST,$D3D9_DST,$GRADLE
    )) {
        if (!(Test-Path $p)) {
            Fail "Missing required path: $p"
        }
    }

    $env:JAVA_HOME = $JBR
    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:Path = "$(Split-Path $GLSLANG -Parent);$JBR\bin;$SDK\platform-tools;$SDK\cmake\3.31.6\bin;C:\Program Files\Git\usr\bin;C:\Program Files\Git\cmd;$(Split-Path $MESON -Parent);$env:Path"

    Run-Native -Exe $ADB -ArgumentList @("start-server") -Quiet | Out-Null

    $devLines = & $ADB devices
    $authorized = @(
        $devLines |
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


    Step "2/6 READ REAL SDL3 ELF SONAME"

    $dynamic = & $READELF --dynamic $SDL3 2>&1
    $dynamic | ForEach-Object { Log $_.ToString() }

    $soname = $null

    foreach ($line in @($dynamic)) {
        $s = $line.ToString()
        if ($s -match "\(SONAME\).*\[(.+?)\]") {
            $soname = $Matches[1]
            break
        }
    }

    if (!$soname) {
        Log ""
        Log "No DT_SONAME found. Falling back to packaged filename."
        $soname = "libSDL3.so"
    }

    Log ""
    Log "REAL SDL3 SONAME: $soname"

    $src = [IO.File]::ReadAllText($WSI)

    $loaderNames = @(
        [regex]::Matches(
            $src,
            '(?i)libSDL3\.so(?:\.[0-9]+)*'
        ) |
        ForEach-Object { $_.Value } |
        Sort-Object -Unique
    )

    Log "DXVK SOURCE SDL3 NAMES:"
    foreach ($n in $loaderNames) {
        Log "  $n"
    }

    if ($loaderNames.Count -eq 0) {
        Fail "No libSDL3.so* loader literal was found in DXVK SDL3 WSI source."
    }


    Step "3/6 PATCH TO EXACT SONAME + ADD dlerror DIAGNOSTIC"

    $backup = "$WSI.before_soname_dlerror_fix.bak"

    if (!(Test-Path $backup)) {
        Copy-Item $WSI $backup -Force
        Log "BACKUP: $backup"
    }

    $patched = $src

    # Make every SDL3 soname literal in this WSI source match the actual ELF.
    foreach ($name in $loaderNames) {
        if ($name -cne $soname) {
            $patched = $patched.Replace($name,$soname)
            Log "SONAME PATCH: $name -> $soname"
        }
    }

    # Add the headers only once.
    if ($patched -notmatch "ZEROHOUR_ANDROID_DLERROR_HEADERS") {
        $headerBlock = @"
#if defined(__ANDROID__)
// ZEROHOUR_ANDROID_DLERROR_HEADERS
#include <dlfcn.h>
#include <cstdio>
#endif

"@

        $patched = $headerBlock + $patched
    }

    # Instrument the exact existing error site only once.
    if ($patched -notmatch "ZH_SDL3_DLOPEN_ERROR") {
        $needle = 'Logger::err("SDL3 WSI: Failed to load SDL3 DLL.");'

        if ($patched.Contains($needle)) {
            $replacement = @'
#if defined(__ANDROID__)
      {
        const char* zhSdlDlError = dlerror();
        std::fprintf(stderr,
          "ZH_SDL3_DLOPEN_ERROR: %s\n",
          zhSdlDlError ? zhSdlDlError : "(dlerror returned null)");
        std::fflush(stderr);
      }
#endif
      Logger::err("SDL3 WSI: Failed to load SDL3 DLL.");
'@

            $patched = $patched.Replace($needle,$replacement)
            Log "DLOPEN ERROR INSTRUMENTATION: ADDED"
        }
        else {
            Fail "Could not find the exact SDL3 WSI loader error site for instrumentation."
        }
    }
    else {
        Log "DLOPEN ERROR INSTRUMENTATION: ALREADY PRESENT"
    }

    [IO.File]::WriteAllText(
        $WSI,
        $patched,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $verify = [IO.File]::ReadAllText($WSI)

    if ($verify -notmatch [regex]::Escape($soname)) {
        Fail "Patched WSI source does not contain the selected SDL3 soname."
    }

    if ($verify -notmatch "ZH_SDL3_DLOPEN_ERROR") {
        Fail "dlerror instrumentation was not written."
    }

    Log "SOURCE PATCH VERIFICATION: PASSED"


    Step "4/6 INCREMENTAL REBUILD DXVK + PACKAGE"

    # Force Ninja to notice WSI source changed.
    (Get-Item $WSI).LastWriteTime = Get-Date

    $compile = Run-Native -Exe $MESON -ArgumentList @(
        "compile","-C",$DXVKBUILD
    )

    if ($compile.Code -ne 0) {
        Fail "Incremental DXVK rebuild failed."
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
        Fail "DXVK rebuild succeeded but D3D8/D3D9 outputs were not found."
    }

    Log "DXVK REBUILD: SUCCESS"
    Log "D3D8: $($built8.FullName)"
    Log "D3D9: $($built9.FullName)"

    Copy-Item $built8.FullName $D3D8_DST -Force
    Copy-Item $built9.FullName $D3D9_DST -Force

    $sdkEscaped = $SDK.Replace("\","\\").Replace(":","\:")
    "sdk.dir=$sdkEscaped" |
        Out-File "$ROOT\android\local.properties" -Encoding ascii

    $oldPref = $ErrorActionPreference
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
        $ErrorActionPreference = $oldPref
    }

    foreach ($line in @($gradleOut)) {
        if ($null -ne $line) {
            Log $line.ToString()
        }
    }

    if ($gradleCode -ne 0 -or !(Test-Path $APK)) {
        Fail "APK packaging failed."
    }

    Log "APK READY: $([math]::Round((Get-Item $APK).Length/1MB,2)) MB"


    Step "5/6 INSTALL UPDATE - PRESERVE GAMEDATA"

    $install = Run-Native -Exe $ADB -ArgumentList @(
        "install","-r","-d",$APK
    )

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "APK update failed. No uninstall was attempted."
    }

    Log "APK UPDATE: SUCCESS"
    Log "GAMEDATA: PRESERVED"


    Step "6/6 LAUNCH + CAPTURE EXACT NEXT BLOCKER"

    Run-Native -Exe $ADB -ArgumentList @(
        "shell","am","force-stop","me.generalsx.zh"
    ) -Quiet | Out-Null

    Run-Native -Exe $ADB -ArgumentList @(
        "logcat","-c"
    ) -Quiet | Out-Null

    Run-Native -Exe $ADB -ArgumentList @(
        "shell","am","start","-n","me.generalsx.zh/.GameActivity"
    ) | Out-Null

    Start-Sleep -Seconds 12

    $gamePid = (& $ADB shell pidof me.generalsx.zh 2>$null | Out-String).Trim()

    $activityDump = (& $ADB shell dumpsys activity activities 2>$null | Out-String)
    $foreground = ($activityDump -match "mResumedActivity.*me\.generalsx\.zh")

    $stderrLines = & $ADB shell run-as me.generalsx.zh cat files/generals-stderr.log 2>&1
    $stderrText = ($stderrLines | Out-String)

    Log ""
    Log "----- ENGINE LAST 350 LINES -----"
    $stderrLines |
        Select-Object -Last 350 |
        ForEach-Object { Log $_.ToString() }

    Log ""
    Log "----- RELEVANT LOGCAT -----"
    & $ADB logcat -d -v time 2>&1 |
        Select-String -Pattern "ZH_SDL3_DLOPEN_ERROR|SDL3|linker|dlopen|cannot locate|library .* not found|DXVK|Vulkan|Mali|GeneralsX" |
        Select-Object -Last 350 |
        ForEach-Object { Log $_.Line }

    Log ""
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($stderrText -match "ZH_SDL3_DLOPEN_ERROR") {
        Log ""
        Fail "DXVK still cannot open SDL3, but the exact Android linker reason is now captured above."
    }

    if ($stderrText -match "SDL3 WSI: Failed to load SDL3 DLL") {
        Fail "SDL3 loader still failed. Check the linker lines above."
    }

    Log ""
    Log "SDL3 LOADER BLOCKER: GONE"

    if ($stderrText -match "VK_EXT_robustness2") {
        Fail "SDL3 is fixed. The next blocker is VK_EXT_robustness2 on the Mali driver."
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "SDL3 is fixed. DXVK device creation now fails for another Vulkan capability; exact reason is above."
    }

    if ($gamePid -and $foreground) {
        Log ""
        Log "SUCCESS: ZERO HOUR IS ALIVE IN FOREGROUND."
        Log "LOOK AT THE PHONE."
        exit 0
    }

    Fail "SDL3 loader advanced, but the game is not the resumed foreground activity after 12 seconds. Exact engine end is above."
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" |
        Out-File $LOG -Append -Encoding utf8

    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
