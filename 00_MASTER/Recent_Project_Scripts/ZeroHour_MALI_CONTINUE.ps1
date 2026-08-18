$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - MALI CONTINUE
#
# Fixes the previous script's mistake:
# molotovgit/CnC-Generals-ZeroHour-Android is the FULL PORT repo,
# not the DXVK source tree. This script keeps that clone, finds/
# initializes the real DXVK checkout inside it, builds only DXVK,
# swaps only d3d8/d3d9 in the already-working current app,
# repackages, installs as update, launches, and checks foreground.
#
# ONE LOG ONLY:
#   C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$PORTROOT = "$ROOT\tools\mali-dxvk\dxvk"   # existing full Molotov repo clone
$SDK  = "$env:LOCALAPPDATA\Android\Sdk"
$NDK  = "$SDK\ndk\27.1.12297006"
$JBR  = "C:\Program Files\Android\Android Studio\jbr"
$ADB  = "$SDK\platform-tools\adb.exe"

$PYTHON = "C:\Users\DELL\AppData\Local\Programs\Python\Python314\python.exe"
$MESON  = "C:\Users\DELL\AppData\Roaming\Python\Python314\Scripts\meson.exe"

$PKGSHIM = "$ROOT\tools\pkg-config-sdl3.py"
$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$GRADLE = "$ROOT\tools\gradle-8.7\bin\gradle.bat"
$APK = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"

$WORK = "$ROOT\tools\mali-dxvk"
$DXVKBUILD = "$WORK\build-android-real"
$CROSS = "$WORK\meson-android-arm64-real.txt"
$GLSLANGDIR = "$WORK\glslang-main-tot"

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
        $output = & $Exe @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
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

function Is-GitRepo([string]$Dir) {
    if (!(Test-Path $Dir)) { return $false }
    $r = Run-Native -Exe "git.exe" -ArgumentList @("-C",$Dir,"rev-parse","--is-inside-work-tree") -Quiet
    return ($r.Code -eq 0 -and $r.Text -match "true")
}

function Find-DxvkTree([string]$Base) {
    $fixed = @(
        "$Base\references\fbraz3-dxvk",
        "$Base\engine\references\fbraz3-dxvk",
        "$Base\engine\references\dxvk",
        "$Base\dxvk"
    )

    foreach ($d in $fixed) {
        if ((Test-Path "$d\meson.build") -and
            (Test-Path "$d\src\d3d8") -and
            (Test-Path "$d\src\d3d9")) {
            return $d
        }
    }

    $mesons = Get-ChildItem $Base -Recurse -File -Filter "meson.build" -ErrorAction SilentlyContinue
    foreach ($m in $mesons) {
        $d = $m.DirectoryName
        if ((Test-Path "$d\src\d3d8") -and (Test-Path "$d\src\d3d9")) {
            return $d
        }
    }

    return $null
}

try {
    Step "1/7 VERIFY CURRENT READY STATE"

    foreach ($p in @($ROOT,$PORTROOT,$ADB,$NDK,$PYTHON,$MESON,$PKGSHIM,$JNI,$GRADLE)) {
        if (!(Test-Path $p)) { Fail "Missing required path: $p" }
    }

    if (!(Test-Path "$PORTROOT\BUILDING.md") -or
        !(Test-Path "$PORTROOT\docs") -or
        !(Test-Path "$PORTROOT\engine")) {
        Fail "Existing clone does not look like the Molotov full Android port."
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
        Fail "Exactly one authorized Android device is required. Found=$($authorized.Count)"
    }

    Log "DEVICE: $((& $ADB shell getprop ro.product.model).Trim())"
    Log "ABI: $((& $ADB shell getprop ro.product.cpu.abi).Trim())"

    foreach ($lib in @("libmain.so","libSDL3.so","libopenal.so","libdxvk_d3d8.so","libdxvk_d3d9.so")) {
        if (!(Test-Path (Join-Path $JNI $lib))) {
            Fail "Current staged runtime is missing: $lib"
        }
    }

    Log "CURRENT ENGINE/RUNTIME: READY"
    Log "MOLOTOV FULL PORT CLONE: READY"


    Step "2/7 FIND THE REAL DXVK SOURCE INSIDE THE FULL PORT"

    $DXVKSRC = Find-DxvkTree $PORTROOT

    if (!$DXVKSRC) {
        Log "DXVK tree not populated yet. Initializing submodules recursively..."

        if (Is-GitRepo $PORTROOT) {
            $r = Run-Native -Exe "git.exe" -ArgumentList @(
                "-C",$PORTROOT,
                "submodule","update","--init","--recursive"
            )
            Log "TOP-LEVEL SUBMODULE RESULT: $($r.Code)"
        }

        # The Molotov repo carries GeneralsX under engine/. Some versions
        # keep the DXVK reference/submodule one level down there.
        if (Is-GitRepo "$PORTROOT\engine") {
            $r = Run-Native -Exe "git.exe" -ArgumentList @(
                "-C","$PORTROOT\engine",
                "submodule","update","--init","--recursive"
            )
            Log "ENGINE SUBMODULE RESULT: $($r.Code)"
        }

        # Also initialize any nested git worktrees that declare .gitmodules.
        $gmFiles = Get-ChildItem $PORTROOT -Recurse -Force -File -Filter ".gitmodules" -ErrorAction SilentlyContinue
        foreach ($gm in $gmFiles) {
            $owner = $gm.DirectoryName
            if (Is-GitRepo $owner) {
                Log "INITIALIZE NESTED SUBMODULES: $owner"
                Run-Native -Exe "git.exe" -ArgumentList @(
                    "-C",$owner,
                    "submodule","update","--init","--recursive"
                ) | Out-Null
            }
        }

        $DXVKSRC = Find-DxvkTree $PORTROOT
    }

    # Last-resort local discovery: extract a DXVK Git URL from .gitmodules,
    # prioritizing fbraz3/Molotov references, then clone only that source.
    if (!$DXVKSRC) {
        Log "No populated DXVK tree yet. Looking for the pinned DXVK URL..."

        $urls = @()

        $candidateTextFiles = @(
            Get-ChildItem $PORTROOT -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq ".gitmodules" -or
                $_.Extension -in @(".md",".txt",".cmake",".ps1",".sh")
            }
        )

        foreach ($f in $candidateTextFiles) {
            try {
                $txt = [IO.File]::ReadAllText($f.FullName)
                $matches = [regex]::Matches(
                    $txt,
                    'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]*dxvk[A-Za-z0-9_.-]*(?:\.git)?',
                    [Text.RegularExpressions.RegexOptions]::IgnoreCase
                )

                foreach ($m in $matches) {
                    $u = $m.Value
                    if ($u -notin $urls) { $urls += $u }
                }
            } catch {}
        }

        # Prefer project-lineage URLs over upstream stock DXVK.
        $urls = @(
            $urls |
            Sort-Object @{
                Expression = {
                    if ($_ -match "molotovgit") { 0 }
                    elseif ($_ -match "fbraz3") { 1 }
                    elseif ($_ -match "ammaarreshi") { 2 }
                    else { 9 }
                }
            }
        )

        foreach ($u in $urls) {
            if ($u -match "doitsujin/dxvk") { continue }

            Log "CHECK DXVK URL: $u"
            $check = Run-Native -Exe "git.exe" -ArgumentList @("ls-remote",$u,"HEAD") -Quiet

            if ($check.Code -eq 0 -and $check.Text -match "HEAD") {
                $manual = "$WORK\actual-dxvk-source"

                if (!(Test-Path "$manual\.git")) {
                    if (Test-Path $manual) { Remove-Item $manual -Recurse -Force }

                    $clone = Run-Native -Exe "git.exe" -ArgumentList @(
                        "clone","--depth","50",$u,$manual
                    )

                    if ($clone.Code -ne 0) { continue }
                }

                if ((Test-Path "$manual\meson.build") -and
                    (Test-Path "$manual\src\d3d8") -and
                    (Test-Path "$manual\src\d3d9")) {
                    $DXVKSRC = $manual
                    break
                }
            }
        }
    }

    if (!$DXVKSRC) {
        Fail "The full Molotov port was cloned correctly, but its real DXVK source/reference could not be resolved automatically."
    }

    Log "REAL DXVK SOURCE:"
    Log $DXVKSRC


    Step "3/7 VERIFY/APPLY MALI-SPECIFIC DXVK CHANGES"

    # Look for evidence already in the DXVK tree.
    $evidence = Get-ChildItem $DXVKSRC -Recurse -File -Include *.cpp,*.h,*.md -ErrorAction SilentlyContinue |
        Select-String -Pattern "nullDescriptor|robustness2|textureCompressionBC|VK_SUBOPTIMAL_KHR|gl_ClipDistance" -ErrorAction SilentlyContinue

    # If the port keeps DXVK changes as patch files, apply only patches
    # that clearly target DXVK and mention the exact mobile capability fixes.
    $patchesApplied = 0

    $patchFiles = Get-ChildItem $PORTROOT -Recurse -File -Include *.patch,*.diff -ErrorAction SilentlyContinue

    foreach ($pf in $patchFiles) {
        $ptext = ""
        try { $ptext = [IO.File]::ReadAllText($pf.FullName) } catch { continue }

        if ($ptext -notmatch "nullDescriptor|robustness2|textureCompressionBC|VK_SUBOPTIMAL_KHR|gl_ClipDistance") {
            continue
        }

        if ($ptext -notmatch "src/(dxvk|d3d8|d3d9|util|vulkan)") {
            continue
        }

        Log "MALI DXVK PATCH FOUND: $($pf.FullName)"

        $check = Run-Native -Exe "git.exe" -ArgumentList @(
            "-C",$DXVKSRC,"apply","--check",$pf.FullName
        ) -Quiet

        if ($check.Code -eq 0) {
            $apply = Run-Native -Exe "git.exe" -ArgumentList @(
                "-C",$DXVKSRC,"apply",$pf.FullName
            )

            if ($apply.Code -eq 0) {
                $patchesApplied++
            }
        }
        else {
            # A patch may already be present in the pinned checkout.
            $reverse = Run-Native -Exe "git.exe" -ArgumentList @(
                "-C",$DXVKSRC,"apply","--reverse","--check",$pf.FullName
            ) -Quiet

            if ($reverse.Code -eq 0) {
                Log "PATCH ALREADY PRESENT: $($pf.Name)"
            }
        }
    }

    # Re-scan after patching.
    $evidence = Get-ChildItem $DXVKSRC -Recurse -File -Include *.cpp,*.h -ErrorAction SilentlyContinue |
        Select-String -Pattern "nullDescriptor|robustness2|textureCompressionBC|VK_SUBOPTIMAL_KHR|gl_ClipDistance" -ErrorAction SilentlyContinue

    if (!$evidence) {
        Fail "Resolved DXVK source has no detectable Mali/null-descriptor capability handling. Refusing to replace the current runtime with a stock-like DXVK build."
    }

    Log "MALI CAPABILITY HANDLING EVIDENCE: FOUND"
    Log "PATCHES APPLIED THIS RUN: $patchesApplied"


    Step "4/7 GET GLSLANG + CONFIGURE DXVK"

    $glslang = Get-Command glslangValidator.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Source

    if (!$glslang) {
        $knownRoots = @(
            "C:\VulkanSDK",
            "$env:LOCALAPPDATA\VulkanSDK",
            $GLSLANGDIR
        ) | Where-Object { Test-Path $_ }

        foreach ($kr in $knownRoots) {
            $glslang = Get-ChildItem $kr -Recurse -File -Filter "glslangValidator.exe" -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
            if ($glslang) { break }
        }
    }

    if (!$glslang) {
        Log "GLSLANG NOT FOUND -> DOWNLOADING KHRONOS MAIN-TOT WINDOWS BINARY"

        $headers = @{
            "User-Agent" = "ZeroHour-Mali-Build"
            "Accept" = "application/vnd.github+json"
        }

        $rel = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/KhronosGroup/glslang/releases/tags/main-tot" `
            -Headers $headers

        $asset = $rel.assets |
            Where-Object {
                $_.name -match "(windows|win)" -and
                $_.name -match "(x64|64)" -and
                $_.name -match "\.zip$"
            } |
            Select-Object -First 1

        if (!$asset) {
            Fail "Khronos main-tot release has no detectable Windows x64 binary ZIP."
        }

        $zipPath = "$WORK\glslang-main-tot-win64.zip"

        Invoke-WebRequest `
            -Uri $asset.browser_download_url `
            -Headers @{ "User-Agent" = "ZeroHour-Mali-Build" } `
            -OutFile $zipPath

        if (Test-Path $GLSLANGDIR) { Remove-Item $GLSLANGDIR -Recurse -Force }
        Expand-Archive $zipPath $GLSLANGDIR -Force

        $glslang = Get-ChildItem $GLSLANGDIR -Recurse -File -Filter "glslangValidator.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }

    if (!$glslang) { Fail "glslangValidator.exe unavailable." }

    $env:Path = "$(Split-Path $glslang -Parent);$env:Path"
    Log "GLSLANG: $glslang"

    $clang  = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android28-clang.cmd"
    $clangpp= "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android28-clang++.cmd"
    $ar     = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-ar.exe"
    $strip  = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe"

    foreach ($p in @($clang,$clangpp,$ar,$strip)) {
        if (!(Test-Path $p)) { Fail "Missing NDK tool: $p" }
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
            Fail "Meson DXVK setup failed."
        }
    }
    finally {
        Pop-Location
    }


    Step "5/7 BUILD ONLY DXVK + SWAP D3D8/D3D9"

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
        Fail "DXVK compiled, but d3d8/d3d9 Android .so outputs were not found."
    }

    Log "NEW D3D8: $($d3d8.FullName)"
    Log "NEW D3D9: $($d3d9.FullName)"

    $oldD3D8 = Join-Path $JNI "libdxvk_d3d8.so"
    $oldD3D9 = Join-Path $JNI "libdxvk_d3d9.so"

    if (!(Test-Path "$oldD3D8.pre_mali.bak")) {
        Copy-Item $oldD3D8 "$oldD3D8.pre_mali.bak" -Force
    }
    if (!(Test-Path "$oldD3D9.pre_mali.bak")) {
        Copy-Item $oldD3D9 "$oldD3D9.pre_mali.bak" -Force
    }

    Copy-Item $d3d8.FullName $oldD3D8 -Force
    Copy-Item $d3d9.FullName $oldD3D9 -Force

    Log "DXVK RUNTIME SWAPPED. ENGINE + GAMEDATA UNCHANGED."


    Step "6/7 PACKAGE + INSTALL UPDATE"

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
        Fail "Gradle packaging failed."
    }

    Log "APK READY: $([math]::Round((Get-Item $APK).Length/1MB,2)) MB"

    $install = Run-Native -Exe $ADB -ArgumentList @(
        "install","-r","-d",$APK
    )

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "APK update failed. No uninstall was attempted, so current app data should remain intact."
    }

    Log "APK UPDATED WITHOUT UNINSTALL -> INTERNAL GAMEDATA PRESERVED"


    Step "7/7 LAUNCH + CHECK REAL FOREGROUND GAME"

    Run-Native -Exe $ADB -ArgumentList @(
        "shell","am","force-stop","me.generalsx.zh"
    ) -Quiet | Out-Null

    Run-Native -Exe $ADB -ArgumentList @("logcat","-c") -Quiet | Out-Null

    Run-Native -Exe $ADB -ArgumentList @(
        "shell","am","start","-n","me.generalsx.zh/.GameActivity"
    ) | Out-Null

    Start-Sleep -Seconds 15

    $gamePid = (& $ADB shell pidof me.generalsx.zh 2>$null | Out-String).Trim()

    $activityText = (& $ADB shell dumpsys activity activities 2>$null | Out-String)
    $foreground = ($activityText -match "mResumedActivity.*me\.generalsx\.zh")

    $stderrLines = & $ADB shell run-as me.generalsx.zh cat files/generals-stderr.log 2>&1

    Log ""
    Log "----- ENGINE LAST LINES -----"
    $stderrLines |
        Select-Object -Last 220 |
        ForEach-Object { Log $_.ToString() }

    $stderrText = ($stderrLines | Out-String)

    Log ""
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($stderrText -match "Required Vulkan extension VK_EXT_robustness2 not supported") {
        Fail "New DXVK still hard-requires VK_EXT_robustness2. The Mali fallback was not active in this built checkout."
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "DXVK device creation still failed. See the engine lines above in this one log."
    }

    if ($gamePid -and $foreground) {
        Log ""
        Log "SUCCESS: ZERO HOUR IS ALIVE IN THE FOREGROUND."
        Log "LOOK AT THE PHONE NOW."
        exit 0
    }

    Fail "The app is not alive as the resumed foreground activity after 15 seconds."
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" |
        Out-File $LOG -Append -Encoding utf8

    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
