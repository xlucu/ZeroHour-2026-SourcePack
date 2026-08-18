$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - SDL3 LOADER DIAGNOSTIC
#
# No build. No source edits. No APK reinstall. No GameData copy.
# Captures the exact reason DXVK cannot open SDL3, plus any
# visible error dialog text automatically.
#
# ONE LOG:
# C:\Users\DELL\Desktop\ZeroHour_SDL3_DIAG.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$WORK = "$ROOT\tools\mali-dxvk"
$DXVKSRC = "$WORK\actual-dxvk-source"

$SDK = "$env:LOCALAPPDATA\Android\Sdk"
$NDK = "$SDK\ndk\27.1.12297006"
$ADB = "$SDK\platform-tools\adb.exe"

$READELF = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe"
$STRINGS = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strings.exe"

$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$SDL3 = "$JNI\libSDL3.so"
$D3D8 = "$JNI\libdxvk_d3d8.so"
$D3D9 = "$JNI\libdxvk_d3d9.so"
$WSI  = "$DXVKSRC\src\wsi\sdl3\wsi_platform_sdl3.cpp"
$WSIF = "$DXVKSRC\src\wsi\sdl3\wsi_platform_sdl3_funcs.h"

$APK = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"
$OUT = "$env:USERPROFILE\Desktop\ZeroHour_SDL3_DIAG.txt"

"" | Out-File $OUT -Encoding utf8

function W([string]$s) {
    Write-Host $s
    $s | Out-File $OUT -Append -Encoding utf8
}

function Section([string]$s) {
    W ""
    W "============================================================"
    W $s
    W "============================================================"
}

function Run([string]$exe, [string[]]$alist) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $o = & $exe @alist 2>&1
        $c = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    foreach ($x in @($o)) {
        if ($null -ne $x) { W $x.ToString() }
    }
    W "EXIT_CODE=$c"
    return $c
}

try {
    Section "1/7 VERIFY"

    foreach ($p in @($ROOT,$ADB,$READELF,$STRINGS,$SDL3,$D3D8,$D3D9,$WSI,$APK)) {
        if (!(Test-Path $p)) {
            W "MISSING: $p"
        } else {
            W "READY: $p"
        }
    }

    & $ADB start-server | Out-Null
    W ""
    & $ADB devices 2>&1 | ForEach-Object { W $_.ToString() }


    Section "2/7 SDL3 ELF SONAME + DEPENDENCIES"

    W "--- libSDL3.so dynamic section ---"
    & $READELF --dynamic $SDL3 2>&1 |
        Select-String -Pattern "SONAME|NEEDED|RPATH|RUNPATH" |
        ForEach-Object { W $_.Line }

    W ""
    W "--- libdxvk_d3d8.so dynamic section ---"
    & $READELF --dynamic $D3D8 2>&1 |
        Select-String -Pattern "SONAME|NEEDED|RPATH|RUNPATH" |
        ForEach-Object { W $_.Line }

    W ""
    W "--- libdxvk_d3d9.so dynamic section ---"
    & $READELF --dynamic $D3D9 2>&1 |
        Select-String -Pattern "SONAME|NEEDED|RPATH|RUNPATH" |
        ForEach-Object { W $_.Line }


    Section "3/7 ACTUAL SDL3 STRINGS IN NEW DXVK"

    W "--- D3D8 strings containing SDL3 / dlopen ---"
    & $STRINGS $D3D8 2>&1 |
        Select-String -Pattern "SDL3|libSDL|dlopen|dlsym|Failed to load" |
        ForEach-Object { W $_.Line }

    W ""
    W "--- D3D9 strings containing SDL3 / dlopen ---"
    & $STRINGS $D3D9 2>&1 |
        Select-String -Pattern "SDL3|libSDL|dlopen|dlsym|Failed to load" |
        ForEach-Object { W $_.Line }


    Section "4/7 SDL3 WSI SOURCE ACTUALLY COMPILED"

    Get-Content $WSI |
        Select-String -Pattern "SDL3|libSDL|LoadLibrary|GetProcAddress|dlopen|dlsym|Failed to load" -Context 3,3 |
        ForEach-Object { W $_.ToString() }

    if (Test-Path $WSIF) {
        W ""
        W "--- function table ---"
        Get-Content $WSIF |
            Select-String -Pattern "SDL_PROC|SDL_Vulkan|SDL_GetWindow|SDL_" |
            Select-Object -First 120 |
            ForEach-Object { W $_.Line }
    }


    Section "5/7 APK NATIVE LIBRARY CONTENTS"

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($APK)
    try {
        $entries = $zip.Entries |
            Where-Object { $_.FullName -like "lib/arm64-v8a/*" } |
            Sort-Object FullName

        foreach ($e in $entries) {
            W ("{0}  {1} bytes" -f $e.FullName,$e.Length)
        }
    }
    finally {
        $zip.Dispose()
    }

    W ""
    W "--- installed package nativeLibraryDir / APK path ---"
    & $ADB shell dumpsys package me.generalsx.zh 2>&1 |
        Select-String -Pattern "codePath=|resourcePath=|nativeLibraryDir=|primaryCpuAbi=" |
        ForEach-Object { W $_.Line }


    Section "6/7 LAUNCH + AUTOMATICALLY CAPTURE THE POPUP"

    & $ADB shell am force-stop me.generalsx.zh | Out-Null
    & $ADB logcat -c | Out-Null

    & $ADB shell am start -n me.generalsx.zh/.GameActivity 2>&1 |
        ForEach-Object { W $_.ToString() }

    Start-Sleep -Seconds 5

    W ""
    W "--- UI AUTOMATOR WINDOW TEXT ---"
    & $ADB shell uiautomator dump /sdcard/zh_ui.xml 2>&1 |
        ForEach-Object { W $_.ToString() }

    $ui = & $ADB shell cat /sdcard/zh_ui.xml 2>&1
    foreach ($line in @($ui)) {
        if ($null -ne $line) { W $line.ToString() }
    }

    W ""
    W "--- WINDOW MANAGER ---"
    & $ADB shell dumpsys window windows 2>&1 |
        Select-String -Pattern "mCurrentFocus|mFocusedApp|me.generalsx.zh|Dialog|Error" |
        Select-Object -Last 100 |
        ForEach-Object { W $_.Line }


    Section "7/7 LINKER + ENGINE LOGS"

    W "--- linker / SDL3 / DXVK logcat ---"
    & $ADB logcat -d -v time 2>&1 |
        Select-String -Pattern "linker|dlopen|dlsym|library .* not found|cannot locate|SDL3|DXVK|Vulkan|GeneralsX|Fatal|FATAL|AndroidRuntime" |
        Select-Object -Last 600 |
        ForEach-Object { W $_.Line }

    W ""
    W "--- generals-stderr.log tail ---"
    $stderr = & $ADB shell run-as me.generalsx.zh cat files/generals-stderr.log 2>&1
    $stderr |
        Select-Object -Last 400 |
        ForEach-Object { W $_.ToString() }

    W ""
    W "============================================================"
    W "DONE"
    W "SEND ME ONLY THIS FILE:"
    W $OUT
}
catch {
    W ""
    W "SCRIPT EXCEPTION:"
    W ($_ | Out-String)
    W ""
    W "SEND ME ONLY THIS FILE:"
    W $OUT
}
