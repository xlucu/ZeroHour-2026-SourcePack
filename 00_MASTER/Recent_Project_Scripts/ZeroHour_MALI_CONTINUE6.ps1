$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - MALI CONTINUE 6
#
# Exact documented Android DXVK fix:
#   libSDL3.so.0  ->  libSDL3.so
# in:
#   src/wsi/sdl3/wsi_platform_sdl3.cpp
#
# Continues from the existing successful DXVK 2.7.1 build.
# NO libmain.so rebuild.
# NO GameData recopy.
#
# ONE LOG:
#   C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$WORK = "$ROOT\tools\mali-dxvk"
$DXVKSRC = "$WORK\actual-dxvk-source"
$DXVKBUILD = "$WORK\build-android-real"

$SDK = "$env:LOCALAPPDATA\Android\Sdk"
$JBR = "C:\Program Files\Android\Android Studio\jbr"
$ADB = "$SDK\platform-tools\adb.exe"

$MESON = "C:\Users\DELL\AppData\Roaming\Python\Python314\Scripts\meson.exe"
$GLSLANG = "$WORK\glslang-main-tot\bin\glslang.exe"

$WSI = "$DXVKSRC\src\wsi\sdl3\wsi_platform_sdl3.cpp"

$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$D3D8_DST = "$JNI\libdxvk_d3d8.so"
$D3D9_DST = "$JNI\libdxvk_d3d9.so"
$SDL3_DST = "$JNI\libSDL3.so"

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

try {
    Step "1/6 VERIFY EXISTING SUCCESSFUL DXVK BUILD"

    foreach ($p in @(
        $ROOT,$WORK,$DXVKSRC,$DXVKBUILD,$WSI,
        $ADB,$MESON,$GLSLANG,$JNI,$D3D8_DST,$D3D9_DST,
        $SDL3_DST,$GRADLE
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
    Log "DXVK BUILD DIR: READY"
    Log "SDL3 PACKAGE LIB: READY"
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"


    Step "2/6 APPLY THE DOCUMENTED ANDROID SDL3 SONAME FIX"

    $text = [IO.File]::ReadAllText($WSI)

    $oldCount = ([regex]::Matches($text, [regex]::Escape("libSDL3.so.0"))).Count
    $newCount = ([regex]::Matches($text, [regex]::Escape("libSDL3.so"))).Count

    Log "SOURCE FILE:"
    Log $WSI
    Log "libSDL3.so.0 occurrences before patch: $oldCount"
    Log "libSDL3.so occurrences before patch: $newCount"

    if ($oldCount -gt 0) {
        $backup = "$WSI.before_android_soname.bak"

        if (!(Test-Path $backup)) {
            Copy-Item $WSI $backup -Force
            Log "BACKUP CREATED:"
            Log $backup
        }

        $patched = $text.Replace("libSDL3.so.0","libSDL3.so")

        [IO.File]::WriteAllText(
            $WSI,
            $patched,
            (New-Object System.Text.UTF8Encoding($false))
        )

        Log "PATCH APPLIED: libSDL3.so.0 -> libSDL3.so"
    }
    elseif ($text -match 'libSDL3\.so') {
        Log "SOURCE ALREADY USES libSDL3.so"
        Log "FORCING INCREMENTAL REBUILD ANYWAY."
        (Get-Item $WSI).LastWriteTime = Get-Date
    }
    else {
        Log ""
        Log "Nearby SDL loader lines:"
        Get-Content $WSI |
            Select-String -Pattern "SDL3|loadLibrary|dlopen|LoadLibrary" |
            Select-Object -First 80 |
            ForEach-Object { Log $_.Line }

        Fail "Expected SDL3 soname string was not found in wsi_platform_sdl3.cpp."
    }

    $verify = [IO.File]::ReadAllText($WSI)

    if ($verify -match 'libSDL3\.so\.0') {
        Fail "Patch verification failed: libSDL3.so.0 is still present."
    }

    if ($verify -notmatch 'libSDL3\.so') {
        Fail "Patch verification failed: libSDL3.so is not present."
    }

    Log "SOURCE PATCH VERIFICATION: PASSED"


    Step "3/6 INCREMENTAL REBUILD DXVK ONLY"

    $compile = Run-Native -Exe $MESON -ArgumentList @(
        "compile","-C",$DXVKBUILD
    )

    if ($compile.Code -ne 0) {
        Fail "Incremental DXVK rebuild failed."
    }

    $built8 = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)^libdxvk_d3d8\.so(?:\..*)?$' } |
        Sort-Object -Property @{Expression='LastWriteTime';Descending=$true}, @{Expression='Length';Descending=$true} |
        Select-Object -First 1

    $built9 = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)^libdxvk_d3d9\.so(?:\..*)?$' } |
        Sort-Object -Property @{Expression='LastWriteTime';Descending=$true}, @{Expression='Length';Descending=$true} |
        Select-Object -First 1

    if (!$built8 -or !$built9) {
        Fail "Rebuild completed but D3D8/D3D9 Android outputs were not found."
    }

    Log "DXVK REBUILD: SUCCESS"
    Log "D3D8: $($built8.FullName)"
    Log "D3D9: $($built9.FullName)"

    # Prove the new source object was rebuilt after this script started.
    $wsiObjects = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '(?i)sdl3.*wsi.*\.(o|obj)$' -or
            $_.FullName -match '(?i)sdl3_wsi'
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 10

    Log ""
    Log "SDL3 WSI BUILD ARTIFACTS:"
    foreach ($o in $wsiObjects) {
        Log "  $($o.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))  $($o.FullName)"
    }


    Step "4/6 STAGE DXVK + PACKAGE APK"

    Copy-Item $built8.FullName $D3D8_DST -Force
    Copy-Item $built9.FullName $D3D9_DST -Force

    Log "DXVK D3D8/D3D9 STAGED"
    Log "libmain.so UNCHANGED"
    Log "libSDL3.so PRESENT: $((Test-Path $SDL3_DST))"
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


    Step "5/6 INSTALL UPDATE - KEEP ALL GAMEDATA"

    $install = Run-Native -Exe $ADB -ArgumentList @(
        "install","-r","-d",$APK
    )

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "APK update failed. No uninstall was attempted."
    }

    Log "APK UPDATE: SUCCESS"
    Log "NO 2GB RECOPY"


    Step "6/6 LAUNCH + CAPTURE THE NEXT REAL GPU RESULT"

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
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($stderrText -match "SDL3 WSI: Failed to load SDL3 DLL") {
        Fail "SDL3 WSI loader still failed even after the exact Android soname patch."
    }

    Log ""
    Log "SDL3 WSI LOADER ERROR: GONE"

    if ($stderrText -match "Required Vulkan extension VK_EXT_robustness2 not supported") {
        Fail "SDL3 loader is fixed. Next confirmed blocker is VK_EXT_robustness2 on this Mali driver."
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "SDL3 loader is fixed, but Vulkan device creation failed for another capability. Exact cause is above."
    }

    if ($gamePid -and $foreground) {
        Log ""
        Log "SUCCESS: ZERO HOUR IS ALIVE IN THE FOREGROUND."
        Log "LOOK AT THE PHONE NOW."
        exit 0
    }

    Fail "SDL3 loader is fixed, but Zero Hour is not the resumed foreground activity after 15 seconds. Exact engine end is above."
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" |
        Out-File $LOG -Append -Encoding utf8

    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
