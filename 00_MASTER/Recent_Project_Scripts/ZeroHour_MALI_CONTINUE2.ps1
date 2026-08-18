$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - MALI CONTINUE 2
#
# Continues exactly where the previous script stopped:
# - does NOT clone the port again
# - does NOT rebuild libmain.so
# - does NOT recopy game data
# - fixes glslang discovery/download
# - builds DXVK only
# - replaces only DXVK .so files
# - repackages/install-updates the APK
# - launches and checks the REAL foreground activity
#
# ONE LOG:
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
$GLSLANGROOT = "$WORK\glslang-fixed"

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

function Find-Glslang {
    param([string[]]$Roots)

    # DXVK's Meson accepts either glslang or glslangValidator.
    foreach ($name in @("glslangValidator.exe","glslang.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty Source
        if ($cmd) { return $cmd }
    }

    foreach ($root in $Roots) {
        if (!$root -or !(Test-Path $root)) { continue }

        foreach ($name in @("glslangValidator.exe","glslang.exe")) {
            $hit = Get-ChildItem $root -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
            if ($hit) { return $hit }
        }
    }

    return $null
}

try {
    Step "1/6 VERIFY READY STATE"

    foreach ($p in @(
        $ROOT,$WORK,$DXVKSRC,$ADB,$NDK,$PYTHON,$MESON,
        $PKGSHIM,$JNI,$GRADLE
    )) {
        if (!(Test-Path $p)) { Fail "Missing required path: $p" }
    }

    if (!(Test-Path "$DXVKSRC\meson.build") -or
        !(Test-Path "$DXVKSRC\src\d3d8") -or
        !(Test-Path "$DXVKSRC\src\d3d9")) {
        Fail "The resolved fbraz3 DXVK checkout is incomplete."
    }

    foreach ($lib in @(
        "libmain.so","libSDL3.so","libopenal.so",
        "libdxvk_d3d8.so","libdxvk_d3d9.so"
    )) {
        if (!(Test-Path (Join-Path $JNI $lib))) {
            Fail "Current staged runtime missing: $lib"
        }
    }

    $env:JAVA_HOME = $JBR
    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:ANDROID_NDK_HOME = $NDK
    $env:Path = "$JBR\bin;$SDK\platform-tools;$SDK\cmake\3.31.6\bin;C:\Program Files\Git\cmd;$(Split-Path $MESON -Parent);$(Split-Path $PYTHON -Parent);$env:Path"

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
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"


    Step "2/6 FIX GLSLANG AUTOMATICALLY"

    $searchRoots = @(
        $WORK,
        "$env:VULKAN_SDK",
        "C:\VulkanSDK",
        "$env:LOCALAPPDATA\VulkanSDK"
    )

    $glslang = Find-Glslang -Roots $searchRoots

    if (!$glslang) {
        Log "No usable glslang binary found locally."
        Log "Reading official Khronos main-tot release assets..."

        $headers = @{
            "User-Agent" = "ZeroHour-Mali-Continue2"
            "Accept" = "application/vnd.github+json"
        }

        $release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/KhronosGroup/glslang/releases/tags/main-tot" `
            -Headers $headers

        Log "AVAILABLE WINDOWS RELEASE ASSETS:"

        $windowsAssets = @(
            $release.assets |
            Where-Object {
                $_.name -match "(?i)windows|win" -and
                $_.name -match "(?i)release" -and
                $_.name -match "(?i)\.zip$"
            }
        )

        foreach ($a in $windowsAssets) {
            Log "  $($a.name)"
        }

        # Prefer release package, regardless of whether its historical name
        # says main/master or whether it includes x64 in the filename.
        $asset = $windowsAssets |
            Sort-Object @{
                Expression = {
                    if ($_.name -match "(?i)x64|amd64") { 0 } else { 1 }
                }
            } |
            Select-Object -First 1

        if (!$asset) {
            Fail "Official main-tot release contains no Windows Release ZIP."
        }

        Log "DOWNLOADING: $($asset.name)"

        New-Item $GLSLANGROOT -ItemType Directory -Force | Out-Null

        $zipPath = Join-Path $GLSLANGROOT $asset.name

        Invoke-WebRequest `
            -Uri $asset.browser_download_url `
            -Headers @{ "User-Agent" = "ZeroHour-Mali-Continue2" } `
            -OutFile $zipPath

        $extractDir = Join-Path $GLSLANGROOT "extracted"
        if (Test-Path $extractDir) {
            Remove-Item $extractDir -Recurse -Force
        }

        Expand-Archive $zipPath $extractDir -Force

        Log "SEARCHING EXTRACTED ARCHIVE FOR glslang/glslangValidator..."

        $glslang = Find-Glslang -Roots @($extractDir)
    }

    if (!$glslang) {
        # Last official fallback: build the tiny standalone tool ourselves.
        # This is slower, but avoids depending on a changing release asset layout.
        Log "Prebuilt archive did not expose the executable."
        Log "FALLBACK: BUILDING OFFICIAL GLSLANG STANDALONE TOOL LOCALLY..."

        $src = Join-Path $GLSLANGROOT "source"
        $bld = Join-Path $GLSLANGROOT "build"

        if (!(Test-Path "$src\.git")) {
            if (Test-Path $src) { Remove-Item $src -Recurse -Force }

            $clone = Run-Native -Exe "git.exe" -ArgumentList @(
                "clone","--depth","1",
                "https://github.com/KhronosGroup/glslang.git",
                $src
            )

            if ($clone.Code -ne 0) {
                Fail "Could not clone official glslang source."
            }
        }

        if (Test-Path $bld) { Remove-Item $bld -Recurse -Force }

        $cmake = "$SDK\cmake\3.31.6\bin\cmake.exe"
        $ninja = "$SDK\cmake\3.31.6\bin\ninja.exe"

        if (!(Test-Path $cmake) -or !(Test-Path $ninja)) {
            Fail "Android SDK CMake/Ninja not found for glslang fallback build."
        }

        $cfg = Run-Native -Exe $cmake -ArgumentList @(
            "-S",$src,
            "-B",$bld,
            "-G","Ninja",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DENABLE_GLSLANG_BINARIES=ON",
            "-DENABLE_SPVREMAPPER=OFF",
            "-DENABLE_OPT=OFF",
            "-DBUILD_TESTING=OFF",
            "-DGLSLANG_TESTS=OFF"
        )

        if ($cfg.Code -ne 0) {
            Fail "Official glslang CMake configure failed."
        }

        $gb = Run-Native -Exe $cmake -ArgumentList @(
            "--build",$bld,
            "--target","glslang-standalone",
            "--parallel","8"
        )

        if ($gb.Code -ne 0) {
            # Target name varies between releases. Build default tree once.
            Log "Named standalone target unavailable; building default glslang tree..."
            $gb = Run-Native -Exe $cmake -ArgumentList @(
                "--build",$bld,
                "--parallel","8"
            )
        }

        if ($gb.Code -ne 0) {
            Fail "Official glslang fallback build failed."
        }

        $glslang = Find-Glslang -Roots @($bld)
    }

    if (!$glslang) {
        Fail "glslang is still unavailable after both official binary and source-build methods."
    }

    $glslangDir = Split-Path $glslang -Parent
    $env:Path = "$glslangDir;$env:Path"

    Log "GLSLANG READY:"
    Log $glslang

    # Prove the executable actually starts before invoking Meson.
    $gt = Run-Native -Exe $glslang -ArgumentList @("--version")
    if ($gt.Code -ne 0) {
        Fail "glslang was found but cannot execute."
    }


    Step "3/6 CONFIGURE + BUILD DXVK ONLY"

    $clang   = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android28-clang.cmd"
    $clangpp = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android28-clang++.cmd"
    $ar      = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-ar.exe"
    $strip   = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe"

    foreach ($p in @($clang,$clangpp,$ar,$strip)) {
        if (!(Test-Path $p)) { Fail "Missing NDK compiler tool: $p" }
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
            "setup",$DXVKBUILD,
            "--cross-file",$CROSS,
            "-Dbuildtype=release"
        )

        if ($setup.Code -ne 0) {
            Fail "Meson setup failed."
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

    $d3d8 = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^libdxvk_d3d8\.so(\..*)?$" } |
        Sort-Object Length -Descending |
        Select-Object -First 1

    $d3d9 = Get-ChildItem $DXVKBUILD -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^libdxvk_d3d9\.so(\..*)?$" } |
        Sort-Object Length -Descending |
        Select-Object -First 1

    if (!$d3d8 -or !$d3d9) {
        Fail "DXVK build completed but d3d8/d3d9 Android libraries were not found."
    }

    Log "DXVK BUILD SUCCESS"
    Log "D3D8: $($d3d8.FullName)"
    Log "D3D9: $($d3d9.FullName)"


    Step "4/6 SWAP ONLY DXVK + PACKAGE APK"

    $dest8 = Join-Path $JNI "libdxvk_d3d8.so"
    $dest9 = Join-Path $JNI "libdxvk_d3d9.so"

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
        if ($null -ne $line) { Log $line.ToString() }
    }

    if ($gradleCode -ne 0 -or !(Test-Path $APK)) {
        Fail "APK packaging failed."
    }

    Log "APK READY: $([math]::Round((Get-Item $APK).Length/1MB,2)) MB"


    Step "5/6 INSTALL UPDATE WITHOUT DELETING DATA"

    $install = Run-Native -Exe $ADB -ArgumentList @(
        "install","-r","-d",$APK
    )

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "APK update failed. Script did NOT uninstall the app, so existing data was preserved."
    }

    Log "APK UPDATED"
    Log "NO 2GB RECOPY"


    Step "6/6 LAUNCH + VERIFY REAL RESULT"

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
    Log "----- ENGINE LAST 240 LINES -----"

    $stderrLines |
        Select-Object -Last 240 |
        ForEach-Object { Log $_.ToString() }

    Log ""
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($stderrText -match "Required Vulkan extension VK_EXT_robustness2 not supported") {
        Fail "This fbraz3 DXVK checkout still hard-requires VK_EXT_robustness2. We now have a clean proof and will move the exact Molotov Mali patch instead of guessing."
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "DXVK device creation still failed for a different reason. The exact cause is above in this one log."
    }

    if ($gamePid -and $foreground) {
        Log ""
        Log "SUCCESS: ZERO HOUR IS ALIVE IN THE FOREGROUND."
        Log "LOOK AT THE PHONE NOW."
        exit 0
    }

    Fail "The app is not the resumed foreground activity after 15 seconds."
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" |
        Out-File $LOG -Append -Encoding utf8

    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
