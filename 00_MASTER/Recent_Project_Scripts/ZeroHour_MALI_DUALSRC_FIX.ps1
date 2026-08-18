$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - MALI DUAL-SOURCE BLEND GATE FIX
#
# Current confirmed blocker on the phone:
#   Skipping: Device does not support required feature 'dualSrcBlend'
#
# For this Android port the game enters DXVK through D3D8 -> D3D9.
# This script makes dualSrcBlend non-required for this Android/D3D8 build,
# keeps the already-proven Android SDL3 direct-dlopen path, rebuilds only
# DXVK, repackages, verifies the native libs, installs as an update, and
# launches the game.
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
$NDK = "$SDK\ndk\27.1.12297006"
$ADB = "$SDK\platform-tools\adb.exe"
$ZIPALIGN = "$SDK\build-tools\35.0.0\zipalign.exe"

$JBR = "C:\Program Files\Android\Android Studio\jbr"
$MESON = "C:\Users\DELL\AppData\Roaming\Python\Python314\Scripts\meson.exe"
$GLSLANG = "$WORK\glslang-main-tot\bin\glslang.exe"
$PYTHON = "C:\Users\DELL\AppData\Local\Programs\Python\Python314\python.exe"

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
        $buf = New-Object byte[] 4
        $n = $fs.Read($buf,0,4)
    }
    finally {
        $fs.Dispose()
    }

    if ($n -ne 4) { return "SHORT" }
    return (($buf | ForEach-Object { $_.ToString("X2") }) -join "")
}

try {
    Step "1/7 VERIFY CURRENT READY STATE"

    foreach ($p in @(
        $ROOT,$WORK,$DXVKSRC,$DXVKBUILD,
        $ADB,$ZIPALIGN,$JBR,$MESON,$GLSLANG,$PYTHON,
        $WSI,$JNI,$D3D8_DST,$D3D9_DST,$SDL3_DST,
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
    Log "CURRENT D3D8 MAGIC: $(Get-Magic $D3D8_DST)"
    Log "CURRENT D3D9 MAGIC: $(Get-Magic $D3D9_DST)"
    Log "CURRENT SDL3 MAGIC: $(Get-Magic $SDL3_DST)"
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"


    Step "2/7 KEEP THE WORKING ANDROID SDL3 DIRECT-DLOPEN PATH"

    $wsiText = [IO.File]::ReadAllText($WSI)

    if ($wsiText.Contains("ZEROHOUR_ANDROID_SDL3_DLOPEN_BEGIN")) {
        Log "ANDROID SDL3 DIRECT-DLOPEN PATCH: ALREADY PRESENT"
    }
    else {
        if ($wsiText -notmatch "ZEROHOUR_ANDROID_SDL3_HEADERS") {
            $incNeedle = '#include <SDL3/SDL_vulkan.h>'

            if (!$wsiText.Contains($incNeedle)) {
                Fail "Could not find SDL3 Vulkan include."
            }

            $incReplacement = @'
#include <SDL3/SDL_vulkan.h>

#if defined(__ANDROID__)
// ZEROHOUR_ANDROID_SDL3_HEADERS
#include <dlfcn.h>
#include <cstdio>
#endif
'@
            $wsiText = $wsiText.Replace($incNeedle,$incReplacement)
        }

        $pattern = '(?s)\s*libsdl\s*=\s*LoadLibraryA\(\s*// FIXME: Get soname as string from meson\s*#if defined\(_WIN32\)\s*"SDL3\.dll"\s*#elif defined\(__APPLE__\)\s*"libSDL3\.0\.dylib"\s*#else\s*"libSDL3\.so"\s*#endif\s*\);\s*if\s*\(libsdl\s*==\s*nullptr\)\s*throw DxvkError\("SDL3 WSI: Failed to load SDL3 DLL\."\);'

        $replacement = @'

#if defined(__ANDROID__)
    // ZEROHOUR_ANDROID_SDL3_DLOPEN_BEGIN
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

        $patchedWsi = [regex]::Replace($wsiText,$pattern,$replacement,1)

        if ($patchedWsi -ceq $wsiText) {
            Fail "Could not reapply the proven Android SDL3 direct-dlopen patch."
        }

        [IO.File]::WriteAllText(
            $WSI,
            $patchedWsi,
            (New-Object System.Text.UTF8Encoding($false))
        )

        Log "ANDROID SDL3 DIRECT-DLOPEN PATCH: REAPPLIED"
    }


    Step "3/7 RELAX ONLY THE dualSrcBlend REQUIREMENT FOR THIS ANDROID BUILD"

    $patcher = @'
import os
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])

candidates = []
for base in [src / "src"]:
    for p in base.rglob("*"):
        if not p.is_file() or p.suffix.lower() not in {".cpp",".h",".hpp",".c",".cc"}:
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = p.read_text(encoding="utf-8", errors="ignore")

        lines = text.splitlines()
        for i, line in enumerate(lines):
            if "dualSrcBlend" in line:
                lo = max(0, i - 10)
                hi = min(len(lines), i + 11)
                ctx = "\n".join(f"{j+1}: {lines[j]}" for j in range(lo, hi))
                candidates.append((p, i, line, ctx))

print(f"DUALSRC_OCCURRENCES={len(candidates)}")
for p, i, line, ctx in candidates:
    print(f"\n--- {p} : {i+1} ---")
    print(ctx)

# Only patch explicit assignments that make dualSrcBlend mandatory/enabled.
# For a D3D8->D3D9 Android build, setting this feature request to false
# is safe: unsupported hardware then remains false and no unsupported
# Vulkan feature is requested.
patterns = [
    re.compile(r'(\.dualSrcBlend\s*=\s*)VK_TRUE(\s*;)'),
    re.compile(r'(\.dualSrcBlend\s*=\s*)true(\s*;)'),
]

patched = []
for p, _, _, _ in candidates:
    try:
        text = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue

    original = text
    n_total = 0

    for pat in patterns:
        def repl(m):
            nonlocal_counter[0] += 1
            rhs = "VK_FALSE" if "VK_TRUE" in m.group(0) else "false"
            return m.group(1) + rhs + m.group(2) + " // ZEROHOUR_ANDROID_D3D8_MALI_DUALSRC_OPTIONAL"

        nonlocal_counter = [0]
        text = pat.sub(repl, text)
        n_total += nonlocal_counter[0]

    if text != original:
        backup = Path(str(p) + ".before_zh_dualsrc.bak")
        if not backup.exists():
            backup.write_text(original, encoding="utf-8")
        p.write_text(text, encoding="utf-8")
        patched.append((p, n_total))

print(f"\nPATCHED_FILES={len(patched)}")
print(f"PATCHED_ASSIGNMENTS={sum(n for _,n in patched)}")
for p,n in patched:
    print(f"PATCHED {n}: {p}")

if not patched:
    sys.exit(23)
'@

    $patcherFile = "$WORK\patch_dualsrc_android.py"
    [IO.File]::WriteAllText(
        $patcherFile,
        $patcher,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $patchResult = Run-Native -Exe $PYTHON -ArgumentList @(
        $patcherFile,$DXVKSRC
    )

    if ($patchResult.Code -eq 23) {
        Fail "Found dualSrcBlend references but no explicit VK_TRUE/true assignment was safe to patch. The source contexts are in this one log."
    }

    if ($patchResult.Code -ne 0) {
        Fail "dualSrcBlend source patcher failed."
    }

    if ($patchResult.Text -notmatch "PATCHED_ASSIGNMENTS=([1-9][0-9]*)") {
        Fail "dualSrcBlend patcher reported no applied assignments."
    }

    Log ""
    Log "dualSrcBlend Android compatibility patch: APPLIED"


    Step "4/7 INCREMENTAL REBUILD DXVK ONLY"

    $compile = Run-Native -Exe $MESON -ArgumentList @(
        "compile","-C",$DXVKBUILD
    )

    if ($compile.Code -ne 0) {
        Fail "DXVK incremental rebuild failed after dualSrcBlend patch."
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
        Fail "Built D3D8 output is not ELF."
    }

    if ((Get-Magic $built9.FullName) -ne "7F454C46") {
        Fail "Built D3D9 output is not ELF."
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
        print("APK_ENTRY", name,
              "method=", info.compress_type,
              "magic=", magic.hex().upper(),
              "size=", info.file_size)
        if magic != b"\x7fELF":
            ok = False
        if info.compress_type != zipfile.ZIP_STORED:
            ok = False
sys.exit(0 if ok else 19)
'@

    $verifyFile = "$WORK\verify_apk_after_dualsrc.py"
    [IO.File]::WriteAllText(
        $verifyFile,
        $verifyPy,
        (New-Object System.Text.UTF8Encoding($false))
    )

    $verify = Run-Native -Exe $PYTHON -ArgumentList @(
        $verifyFile,$APK
    )

    if ($verify.Code -ne 0) {
        Fail "APK native-library verification failed."
    }

    $za = Run-Native -Exe $ZIPALIGN -ArgumentList @(
        "-c","-P","16","-v","4",$APK
    )

    if ($za.Code -ne 0) {
        Fail "APK 16K alignment verification failed."
    }

    Log "APK VERIFIED: ELF + STORED + ALIGNED"
    Log "APK SIZE: $([math]::Round((Get-Item $APK).Length/1MB,2)) MB"


    Step "6/7 INSTALL UPDATE - PRESERVE ALL GAMEDATA"

    $install = Run-Native -Exe $ADB -ArgumentList @(
        "install","-r","-d",$APK
    )

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "APK update install failed. No uninstall was attempted."
    }

    Log "APK UPDATE: SUCCESS"
    Log "GAMEDATA: PRESERVED"


    Step "7/7 LAUNCH + CAPTURE NEXT REAL MALI RESULT"

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
    Log "----- ENGINE LAST 420 LINES -----"
    $stderrLines |
        Select-Object -Last 420 |
        ForEach-Object { Log $_.ToString() }

    Log ""
    Log "----- RELEVANT LOGCAT -----"
    $logcat = & $ADB logcat -d -v time 2>&1
    $logcat |
        Select-String -Pattern "dualSrcBlend|robustness2|Required Vulkan|Skipping: Device|No adapters|DxvkAdapter|DXVK|Vulkan|Mali|SDL3|bad ELF|FATAL|AndroidRuntime" |
        Select-Object -Last 500 |
        ForEach-Object { Log $_.Line }

    Log ""
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($stderrText -match "required feature 'dualSrcBlend'") {
        Fail "dualSrcBlend is still being required by another source path. The exact source audit above shows all local occurrences."
    }

    Log ""
    Log "dualSrcBlend ADAPTER GATE: GONE"

    if ($stderrText -match "VK_EXT_robustness2|robustBufferAccess2|nullDescriptor") {
        Fail "dualSrcBlend is cleared. Next confirmed Mali blocker is robustness2/nullDescriptor handling."
    }

    if ($stderrText -match "Skipping: Device does not support required feature '([^']+)'") {
        $feature = $Matches[1]
        Fail "dualSrcBlend is cleared. Next missing required Vulkan feature is: $feature"
    }

    if ($stderrText -match "Required Vulkan extension ([A-Za-z0-9_]+) not supported") {
        $ext = $Matches[1]
        Fail "dualSrcBlend is cleared. Next missing Vulkan extension is: $ext"
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "Adapter enumeration advanced, but Vulkan device creation failed. Exact cause is above."
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
