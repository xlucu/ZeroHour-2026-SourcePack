$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - MALI DXVK SWITCH
# Goal:
#   Replace the current DXVK runtime that hard-requires
#   VK_EXT_robustness2 with a Mali-oriented DXVK fork/runtime,
#   then repackage the already-built Android app.
#
# Reuses:
#   - Existing GeneralsZH-Android-CLEAN project
#   - Existing fresh libmain.so
#   - Existing game data already inside app storage
#
# One log only:
#   C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$SDK  = "$env:LOCALAPPDATA\Android\Sdk"
$NDK  = "$SDK\ndk\27.1.12297006"
$JBR  = "C:\Program Files\Android\Android Studio\jbr"
$ADB  = "$SDK\platform-tools\adb.exe"

$LOG  = "$env:USERPROFILE\Desktop\ZeroHour_MALI_LOG.txt"

$TOOLS = "$ROOT\tools"
$MALIROOT = "$TOOLS\mali-dxvk"
$DXVKSRC = "$MALIROOT\dxvk"
$DXVKBUILD = "$MALIROOT\build-android"
$CROSS = "$MALIROOT\meson-android-arm64.txt"

$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$GRADLE = "$TOOLS\gradle-8.7\bin\gradle.bat"
$APK = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"

$PKGSHIM = "$ROOT\tools\pkg-config-sdl3.py"

"" | Out-File $LOG -Encoding utf8

function Log([string]$s) {
    Write-Host $s
    $s | Out-File $LOG -Append -Encoding utf8
}

function Step([string]$s) {
    Log ""
    Log "============================================================"
    Log $s
    Log "============================================================"
}

function Fail([string]$s) {
    Log ""
    Log "FAILED: $s"
    Log "SEND ME ONLY:"
    Log $LOG
    throw $s
}

function Native {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$false)][string[]]$ArgumentList = @()
    )

    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $o = & $Exe @ArgumentList 2>&1
        $c = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }

    $lines = @()
    foreach ($x in @($o)) {
        if ($null -ne $x) {
            $t = $x.ToString()
            $lines += $t
            Log $t
        }
    }

    [pscustomobject]@{ Code=$c; Text=($lines -join "`r`n") }
}

try {
    Step "1/7 VERIFY PHONE + EXISTING BUILD"

    foreach ($p in @($ROOT,$ADB,$NDK,$JNI,$GRADLE,$PKGSHIM)) {
        if (!(Test-Path $p)) { Fail "Missing required path: $p" }
    }

    $localMain = Join-Path $JNI "libmain.so"
    if (!(Test-Path $localMain)) { Fail "Fresh libmain.so is not staged." }

    $env:JAVA_HOME = $JBR
    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:ANDROID_NDK_HOME = $NDK
    $env:Path = "$JBR\bin;$SDK\platform-tools;C:\Users\DELL\AppData\Roaming\Python\Python314\Scripts;C:\Users\DELL\AppData\Local\Programs\Python\Python314;C:\Program Files\Git\cmd;$env:Path"

    Native -Exe $ADB -ArgumentList @("start-server") | Out-Null

    $devs = & $ADB devices
    $ok = @($devs | Select-Object -Skip 1 | Where-Object { $_ -match "^\S+\s+device$" })
    if ($ok.Count -ne 1) { Fail "Exactly one authorized device required. Found=$($ok.Count)" }

    Log "DEVICE: $((& $ADB shell getprop ro.product.model).Trim())"
    Log "GPU TARGET: Mali"
    Log "FRESH ENGINE: $([math]::Round((Get-Item $localMain).Length/1MB,2)) MB"


    Step "2/7 FIND THE MALI DXVK FORK AUTOMATICALLY"

    New-Item $MALIROOT -ItemType Directory -Force | Out-Null

    $headers = @{
        "User-Agent" = "ZeroHour-Mali-DXVK"
        "Accept" = "application/vnd.github+json"
    }

    $repos = Invoke-RestMethod `
        -Uri "https://api.github.com/users/molotovgit/repos?per_page=100" `
        -Headers $headers

    $dxvkRepo = $repos |
        Where-Object {
            $_.name -match "dxvk" -or
            $_.description -match "DXVK"
        } |
        Select-Object -First 1

    if (!$dxvkRepo) {
        Log "No DXVK-named repo found under molotovgit; trying documented lineage candidates."

        $chosen = "https://github.com/molotovgit/dxvk.git"
        Log "CHECK: $chosen"
        $r = Native -Exe "git.exe" -ArgumentList @("ls-remote",$chosen,"HEAD")
        if ($r.Code -ne 0 -or $r.Text -notmatch "HEAD") {
            Fail "No public molotovgit DXVK fork was found. I will not fall back to stock DXVK because stock DXVK is the exact runtime that fails on this Mali driver."
        }
        $cloneUrl = $chosen
    }
    else {
        $cloneUrl = $dxvkRepo.clone_url
        Log "DXVK REPO: $($dxvkRepo.full_name)"
    }

    if (!(Test-Path "$DXVKSRC\.git")) {
        if (Test-Path $DXVKSRC) { Remove-Item $DXVKSRC -Recurse -Force }
        $cl = Native -Exe "git.exe" -ArgumentList @("clone","--depth","50",$cloneUrl,$DXVKSRC)
        if ($cl.Code -ne 0) { Fail "DXVK clone failed." }
    } else {
        Push-Location $DXVKSRC
        try {
            Native -Exe "git.exe" -ArgumentList @("fetch","--depth","1","origin") | Out-Null
            Native -Exe "git.exe" -ArgumentList @("reset","--hard","origin/HEAD") | Out-Null
        } finally {
            Pop-Location
        }
    }

    if (!(Test-Path "$DXVKSRC\meson.build")) {
        Fail "Cloned repository is not a DXVK source tree."
    }

    Log "DXVK SOURCE READY: $DXVKSRC"

    # Confirm this is a Mali-oriented fork and not merely stock DXVK.
    Push-Location $DXVKSRC
    try {
        $hist = Native -Exe "git.exe" -ArgumentList @(
            "log","-50","--oneline","--regexp-ignore-case",
            "--grep=Mali","--grep=nullDescriptor","--grep=robustness","--grep=dummy descriptor"
        )
    } finally {
        Pop-Location
    }

    $mobileCode = Get-ChildItem $DXVKSRC -Recurse -File -Include *.cpp,*.h,*.md -ErrorAction SilentlyContinue |
        Select-String -Pattern "dummy.{0,50}descriptor|descriptor.{0,50}dummy|Mali.{0,80}(descriptor|robust|Vulkan)|nullDescriptor.{0,80}(fallback|optional|dummy)" -ErrorAction SilentlyContinue

    if (($hist.Text -notmatch "Mali|nullDescriptor|robust|dummy") -and !$mobileCode) {
        Fail "The cloned DXVK tree does not show the documented Mali/null-descriptor fallback. Refusing to replace the current runtime with another stock-like build."
    }

    Log "MALI / NULL-DESCRIPTOR FALLBACK EVIDENCE FOUND"


    Step "3/7 PREPARE GLSLANG + MESON CROSS BUILD"

    $glslang = Get-Command glslangValidator.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source

    if (!$glslang) {
        $known = Get-ChildItem @(
            "C:\VulkanSDK",
            "C:\Program Files",
            "$env:LOCALAPPDATA"
        ) -Recurse -File -Filter "glslangValidator.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName

        if ($known) { $glslang = $known }
    }

    if (!$glslang) {
        Log "glslangValidator not found; downloading official Khronos glslang Windows binary..."

        $rels = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/KhronosGroup/glslang/releases/latest" `
            -Headers $headers

        $asset = $rels.assets |
            Where-Object {
                $_.name -match "(windows|win).*(x64|64).*\.zip$" -or
                $_.name -match "(x64|64).*(windows|win).*\.zip$"
            } |
            Select-Object -First 1

        if (!$asset) {
            Fail "Could not find a Windows x64 glslang release asset."
        }

        $gz = "$MALIROOT\glslang.zip"
        $gd = "$MALIROOT\glslang"

        Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $gz

        if (Test-Path $gd) { Remove-Item $gd -Recurse -Force }
        Expand-Archive $gz $gd -Force

        $glslang = Get-ChildItem $gd -Recurse -File -Filter "glslangValidator.exe" |
            Select-Object -First 1 -ExpandProperty FullName
    }

    if (!$glslang) { Fail "glslangValidator.exe is still unavailable." }

    $env:Path = "$(Split-Path $glslang -Parent);$env:Path"
    Log "GLSLANG: $glslang"

    $clang  = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android28-clang.cmd"
    $clangp = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android28-clang++.cmd"
    $ar     = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-ar.exe"
    $strip  = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe"

    foreach ($p in @($clang,$clangp,$ar,$strip)) {
        if (!(Test-Path $p)) { Fail "NDK compiler component missing: $p" }
    }

    $py = "C:\Users\DELL\AppData\Local\Programs\Python\Python314\python.exe"
    if (!(Test-Path $py)) { Fail "Python not found: $py" }

    # Meson can execute the existing SDL3 pkg-config shim directly through Python.
    $crossText = @"
[binaries]
c = '$($clang.Replace("\","/"))'
cpp = '$($clangp.Replace("\","/"))'
ar = '$($ar.Replace("\","/"))'
strip = '$($strip.Replace("\","/"))'
pkg-config = ['$($py.Replace("\","/"))', '$($PKGSHIM.Replace("\","/"))']

[built-in options]
c_args = ['-DVK_ENABLE_BETA_EXTENSIONS', '-DVK_USE_PLATFORM_ANDROID_KHR']
cpp_args = ['-DVK_ENABLE_BETA_EXTENSIONS', '-DVK_USE_PLATFORM_ANDROID_KHR']

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
"@

    [IO.File]::WriteAllText($CROSS,$crossText,(New-Object System.Text.UTF8Encoding($false)))

    $meson = Get-Command meson.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source

    if (!$meson) { Fail "meson.exe not found." }

    if (Test-Path $DXVKBUILD) { Remove-Item $DXVKBUILD -Recurse -Force }

    Push-Location $DXVKSRC
    try {
        $setup = Native -Exe $meson -ArgumentList @(
            "setup",$DXVKBUILD,
            "--cross-file",$CROSS,
            "-Dbuildtype=release"
        )
        if ($setup.Code -ne 0) { Fail "Meson setup failed." }
    } finally {
        Pop-Location
    }


    Step "4/7 BUILD MALI DXVK"

    $compile = Native -Exe $meson -ArgumentList @(
        "compile","-C",$DXVKBUILD
    )
    if ($compile.Code -ne 0) { Fail "Mali DXVK build failed." }

    $d3d8 = Get-ChildItem $DXVKBUILD -Recurse -File |
        Where-Object { $_.Name -match "^libdxvk_d3d8\.so(\..*)?$" } |
        Sort-Object Length -Descending |
        Select-Object -First 1

    $d3d9 = Get-ChildItem $DXVKBUILD -Recurse -File |
        Where-Object { $_.Name -match "^libdxvk_d3d9\.so(\..*)?$" } |
        Sort-Object Length -Descending |
        Select-Object -First 1

    if (!$d3d8 -or !$d3d9) {
        Fail "DXVK build finished but d3d8/d3d9 Android libraries were not found."
    }

    Log "MALI D3D8: $($d3d8.FullName)"
    Log "MALI D3D9: $($d3d9.FullName)"


    Step "5/7 REPLACE ONLY DXVK RUNTIME + PACKAGE APK"

    Copy-Item $d3d8.FullName (Join-Path $JNI "libdxvk_d3d8.so") -Force
    Copy-Item $d3d9.FullName (Join-Path $JNI "libdxvk_d3d9.so") -Force

    $sdkEscaped = $SDK.Replace("\","\\").Replace(":","\:")
    "sdk.dir=$sdkEscaped" | Out-File "$ROOT\android\local.properties" -Encoding ascii

    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $go = & $GRADLE -p "$ROOT\android" :app:assembleDebug -PSAGE_SKIP_NATIVE_BUILD=true --no-daemon 2>&1
        $gc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }

    $go | ForEach-Object { Log $_.ToString() }

    if ($gc -ne 0 -or !(Test-Path $APK)) {
        Fail "APK packaging failed."
    }

    Log "APK READY: $([math]::Round((Get-Item $APK).Length/1MB,2)) MB"


    Step "6/7 INSTALL UPDATE WITHOUT TOUCHING GAME DATA"

    $ins = Native -Exe $ADB -ArgumentList @("install","-r","-d",$APK)
    if ($ins.Code -ne 0 -or $ins.Text -notmatch "Success") {
        Fail "APK update failed. Existing app/data were left as-is if Android rejected the update."
    }

    Log "APK UPDATED. EXISTING INTERNAL GAMEDATA PRESERVED."


    Step "7/7 LAUNCH + VERIFY REAL FOREGROUND ACTIVITY"

    Native -Exe $ADB -ArgumentList @("shell","am","force-stop","me.generalsx.zh") | Out-Null
    Native -Exe $ADB -ArgumentList @("logcat","-c") | Out-Null

    Native -Exe $ADB -ArgumentList @(
        "shell","am","start","-n","me.generalsx.zh/.GameActivity"
    ) | Out-Null

    Start-Sleep -Seconds 12

    $pid = (& $ADB shell pidof me.generalsx.zh 2>$null | Out-String).Trim()
    $resumed = (& $ADB shell dumpsys activity activities 2>$null | Select-String "mResumedActivity.*me.generalsx.zh" | Out-String).Trim()

    $stderr = & $ADB shell run-as me.generalsx.zh cat files/generals-stderr.log 2>&1

    Log ""
    Log "----- ENGINE END -----"
    $stderr | Select-Object -Last 160 | ForEach-Object { Log $_.ToString() }

    Log ""
    Log "PID: $pid"
    Log "RESUMED: $resumed"

    if ($pid -and $resumed -match "me.generalsx.zh") {
        Log ""
        Log "SUCCESS: GAME IS ALIVE AND FOREGROUND."
        Log "LOOK AT THE PHONE."
        exit 0
    }

    Log ""
    Log "GAME IS NOT ALIVE IN FOREGROUND."
    Log "SEND ME ONLY:"
    Log $LOG
    exit 2
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" | Out-File $LOG -Append -Encoding utf8
    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
