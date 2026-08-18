$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - ANDROID SDL3 DLOPEN FIX
#
# What the latest audit proved:
# - DXVK fails at LoadLibraryA("libSDL3.so"), BEFORE GetProcAddress.
# - libSDL3.so exists and its ELF SONAME is correct.
#
# Android-only fix:
# - bypass DXVK Native's Win32 compatibility LoadLibraryA wrapper
# - call Android/POSIX dlopen("libSDL3.so", RTLD_NOW|RTLD_LOCAL)
# - print dlerror() if Android still refuses it
# - keep GetProcAddress function loading unchanged
#
# Then incrementally rebuild DXVK only, package, update-install,
# launch, and capture the next real blocker.
#
# NO libmain.so rebuild.
# NO GameData recopy.
# NO uninstall.
#
# ONE LOG:
# C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$WORK = "$ROOT\tools\mali-dxvk"
$DXVKSRC = "$WORK\actual-dxvk-source"
$DXVKBUILD = "$WORK\build-android-real"

$SDK = "$env:LOCALAPPDATA\Android\Sdk"
$NDK = "$SDK\ndk\27.1.12297006"
$ADB = "$SDK\platform-tools\adb.exe"

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
        $output = & $Exe @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPref
    }

    $lines = @()
    foreach ($item in @($output)) {
        if ($null -ne $item) {
            $line = $item.ToString()
            $lines += $line
            if (!$Quiet) { Log $line }
        }
    }

    return [pscustomobject]@{
        Code = $code
        Text = ($lines -join "`r`n")
    }
}

try {
    Step "1/6 VERIFY READY STATE"

    foreach ($p in @(
        $ROOT,$WORK,$DXVKSRC,$DXVKBUILD,$WSI,
        $ADB,$NDK,$JBR,$MESON,$GLSLANG,
        $SDL3,$D3D8_DST,$D3D9_DST,$GRADLE
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

    $deviceLines = & $ADB devices
    $authorized = @(
        $deviceLines |
        Select-Object -Skip 1 |
        Where-Object { $_ -match "^\S+\s+device$" }
    )

    if ($authorized.Count -ne 1) {
        Fail "Exactly one authorized Android device required. Found=$($authorized.Count)"
    }

    Log "DEVICE: $((& $ADB shell getprop ro.product.model).Trim())"
    Log "ABI: $((& $ADB shell getprop ro.product.cpu.abi).Trim())"
    Log "DXVK BUILD: READY"
    Log "libSDL3.so: READY"
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"


    Step "2/6 PATCH THE EXACT FAILING SDL3 LOAD SITE"

    $source = [IO.File]::ReadAllText($WSI)

    # Remove our Android patch if already present so reruns are deterministic.
    $beginMarker = "// ZEROHOUR_ANDROID_SDL3_DLOPEN_BEGIN"
    $endMarker   = "// ZEROHOUR_ANDROID_SDL3_DLOPEN_END"

    if ($source.Contains($beginMarker) -and $source.Contains($endMarker)) {
        Log "ANDROID DLOPEN PATCH ALREADY PRESENT."
        Log "TOUCHING SOURCE FOR A CLEAN INCREMENTAL REBUILD."
        (Get-Item $WSI).LastWriteTime = Get-Date
    }
    else {
        # Add required Android headers after SDL Vulkan include.
        if ($source -notmatch "ZEROHOUR_ANDROID_SDL3_HEADERS") {
            $incNeedle = '#include <SDL3/SDL_vulkan.h>'

            if (!$source.Contains($incNeedle)) {
                Fail "Could not find SDL_vulkan include in WSI source."
            }

            $incReplacement = @'
#include <SDL3/SDL_vulkan.h>

#if defined(__ANDROID__)
// ZEROHOUR_ANDROID_SDL3_HEADERS
#include <dlfcn.h>
#include <cstdio>
#endif
'@

            $source = $source.Replace($incNeedle,$incReplacement)
        }

        # Replace constructor LoadLibraryA block using the exact source shape
        # shown by the user's audit. Regex tolerates whitespace.
        $pattern = '(?s)\s*libsdl\s*=\s*LoadLibraryA\(\s*// FIXME: Get soname as string from meson\s*#if defined\(_WIN32\)\s*"SDL3\.dll"\s*#elif defined\(__APPLE__\)\s*"libSDL3\.0\.dylib"\s*#else\s*"libSDL3\.so"\s*#endif\s*\);\s*if\s*\(libsdl\s*==\s*nullptr\)\s*throw DxvkError\("SDL3 WSI: Failed to load SDL3 DLL\."\);'

        $replacement = @'

#if defined(__ANDROID__)
    // ZEROHOUR_ANDROID_SDL3_DLOPEN_BEGIN
    // Android: use the platform loader directly. This bypasses the
    // DXVK Native Win32-compat LoadLibraryA wrapper which returned null
    // even though libSDL3.so is packaged and already has the right SONAME.
    dlerror();
    void* zhSdlHandle = dlopen("libSDL3.so", RTLD_NOW | RTLD_LOCAL);
    libsdl = reinterpret_cast<HMODULE>(zhSdlHandle);

    if (libsdl == nullptr) {
      const char* zhDlError = dlerror();
      std::fprintf(stderr,
        "ZH_ANDROID_SDL3_DLOPEN_FAILED: %s\n",
        zhDlError ? zhDlError : "(dlerror returned null)");
      std::fflush(stderr);
      throw DxvkError("SDL3 WSI: Android dlopen(libSDL3.so) failed.");
    }

    std::fprintf(stderr, "ZH_ANDROID_SDL3_DLOPEN_OK\n");
    std::fflush(stderr);
    // ZEROHOUR_ANDROID_SDL3_DLOPEN_END
#else
    libsdl = LoadLibraryA( // FIXME: Get soname as string from meson
#if defined(_WIN32)
        "SDL3.dll"
#elif defined(__APPLE__)
        "libSDL3.0.dylib"
#else
        "libSDL3.so"
#endif
      );

    if (libsdl == nullptr)
      throw DxvkError("SDL3 WSI: Failed to load SDL3 DLL.");
#endif
'@

        $patched = [regex]::Replace($source,$pattern,$replacement,1)

        if ($patched -ceq $source) {
            Log "Exact constructor text was not matched. Showing first 60 lines:"
            Get-Content $WSI |
                Select-Object -First 60 |
                ForEach-Object { Log $_ }

            Fail "Could not patch the audited SDL3 LoadLibraryA block."
        }

        $backup = "$WSI.before_android_direct_dlopen.bak"
        if (!(Test-Path $backup)) {
            Copy-Item $WSI $backup -Force
            Log "BACKUP CREATED:"
            Log $backup
        }

        [IO.File]::WriteAllText(
            $WSI,
            $patched,
            (New-Object System.Text.UTF8Encoding($false))
        )

        Log "ANDROID DIRECT dlopen PATCH: APPLIED"
    }

    $verify = [IO.File]::ReadAllText($WSI)

    if (!$verify.Contains("ZH_ANDROID_SDL3_DLOPEN_FAILED") -or
        !$verify.Contains("ZH_ANDROID_SDL3_DLOPEN_OK")) {
        Fail "Patch verification failed."
    }

    Log "PATCH VERIFICATION: PASSED"


    Step "3/6 INCREMENTAL DXVK REBUILD ONLY"

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

    Log "DXVK REBUILD: SUCCESS"
    Log "D3D8: $($built8.FullName)"
    Log "D3D9: $($built9.FullName)"


    Step "4/6 STAGE DXVK + PACKAGE APK"

    Copy-Item $built8.FullName $D3D8_DST -Force
    Copy-Item $built9.FullName $D3D9_DST -Force

    Log "DXVK STAGED"
    Log "libmain.so UNCHANGED"
    Log "GameData UNCHANGED"

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


    Step "6/6 LAUNCH + CAPTURE EXACT RESULT"

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
    Log "----- ENGINE LAST 380 LINES -----"
    $stderrLines |
        Select-Object -Last 380 |
        ForEach-Object { Log $_.ToString() }

    Log ""
    Log "----- RELEVANT LOGCAT -----"
    & $ADB logcat -d -v time 2>&1 |
        Select-String -Pattern "ZH_ANDROID_SDL3|SDL3|dlopen|linker|cannot locate|library .* not found|DXVK|Vulkan|Mali|FATAL|AndroidRuntime" |
        Select-Object -Last 450 |
        ForEach-Object { Log $_.Line }

    Log ""
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($stderrText -match "ZH_ANDROID_SDL3_DLOPEN_FAILED") {
        Fail "Direct Android dlopen also failed. The exact linker reason is now printed above."
    }

    if ($stderrText -match "ZH_ANDROID_SDL3_DLOPEN_OK") {
        Log ""
        Log "DIRECT ANDROID SDL3 DLOPEN: SUCCESS"
    }

    if ($stderrText -match "SDL3 WSI: Failed to load SDL_[A-Za-z0-9_]+") {
        Fail "SDL3 library now opens, but DXVK is missing one exact SDL3 function. Its name is printed above."
    }

    if ($stderrText -match "Failed to initialize video subsystem") {
        Fail "SDL3 library and symbols loaded; SDL video subsystem initialization is the next blocker."
    }

    if ($stderrText -match "VK_EXT_robustness2") {
        Fail "SDL3 blocker is gone. We are back at the Mali Vulkan robustness2 blocker."
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "SDL3 blocker is gone. Vulkan device creation is now the blocker; exact reason is above."
    }

    if ($gamePid -and $foreground) {
        Log ""
        Log "SUCCESS: ZERO HOUR IS ALIVE IN FOREGROUND."
        Log "LOOK AT THE PHONE NOW."
        exit 0
    }

    Fail "The SDL3 loader advanced, but the game is not the resumed foreground activity after 15 seconds. Exact end is above."
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" |
        Out-File $LOG -Append -Encoding utf8

    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
