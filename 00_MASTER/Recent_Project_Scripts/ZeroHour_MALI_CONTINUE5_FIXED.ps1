$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - MALI CONTINUE 5
#
# Current runtime blocker:
#   SDL3 WSI: Failed to load SDL3 DLL.
#
# This script does NOT guess the correct Android SDL3 soname.
# It reads the ORIGINAL DXVK runtime backup that already got
# past SDL3 on this same phone/app, extracts the SDL3 soname
# from that binary, patches the new DXVK WSI to use the same
# name, incrementally rebuilds DXVK only, repackages and tests.
#
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

$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$GRADLE = "$ROOT\tools\gradle-8.7\bin\gradle.bat"
$APK = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"

$CURRENT8 = "$JNI\libdxvk_d3d8.so"
$CURRENT9 = "$JNI\libdxvk_d3d9.so"
$OLD8 = "$CURRENT8.before_mali.bak"

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

function Get-SdlNamesFromBinary([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)

    $matches = [regex]::Matches(
        $ascii,
        '(?i)(?:lib)?SDL3(?:\.so(?:\.[0-9]+)*|\.dll)'
    )

    return @(
        $matches |
        ForEach-Object { $_.Value } |
        Sort-Object -Unique
    )
}

function Get-SdlSourceMatches([string]$Base) {
    $results = @()

    $files = Get-ChildItem $Base -Recurse -File -Include *.cpp,*.h -ErrorAction SilentlyContinue

    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f.FullName)

        $ms = [regex]::Matches(
            $text,
            '(?i)(?:lib)?SDL3(?:\.so(?:\.[0-9]+)*|\.dll)'
        )

        foreach ($m in $ms) {
            $results += [pscustomobject]@{
                File = $f.FullName
                Name = $m.Value
            }
        }
    }

    return @($results)
}

try {
    Step "1/6 VERIFY SUCCESSFUL BUILD STATE"

    foreach ($p in @(
        $ROOT,$WORK,$DXVKSRC,$DXVKBUILD,
        $ADB,$MESON,$GLSLANG,$JNI,$GRADLE,
        $CURRENT8,$CURRENT9,$OLD8
    )) {
        if (!(Test-Path $p)) {
            Fail "Missing required ready-state path: $p"
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
    Log "EXISTING DXVK BUILD DIR: READY"
    Log "ORIGINAL PRE-MALI DXVK BACKUP: READY"
    Log "NO ENGINE REBUILD"
    Log "NO GAMEDATA RECOPY"


    Step "2/6 LEARN THE WORKING SDL3 SONAME FROM THE OLD RUNTIME"

    $oldNames = Get-SdlNamesFromBinary $OLD8
    $newNames = Get-SdlNamesFromBinary $CURRENT8

    Log "OLD WORKING-RUNTIME SDL3 NAMES:"
    foreach ($n in $oldNames) { Log "  $n" }

    Log ""
    Log "CURRENT NEW-RUNTIME SDL3 NAMES:"
    foreach ($n in $newNames) { Log "  $n" }

    if ($oldNames.Count -eq 0) {
        Fail "Could not extract any SDL3 library name from the original working DXVK backup."
    }

    # Prefer the unversioned Android soname if it exists in the known-good binary.
    $desired = $oldNames |
        Where-Object { $_ -ceq "libSDL3.so" } |
        Select-Object -First 1

    if (!$desired) {
        $desired = $oldNames |
            Where-Object { $_ -match '(?i)^libSDL3\.so' } |
            Select-Object -First 1
    }

    if (!$desired) {
        $desired = $oldNames | Select-Object -First 1
    }

    Log ""
    Log "KNOWN-GOOD SDL3 SONAME SELECTED:"
    Log $desired

    $sourceMatches = Get-SdlSourceMatches "$DXVKSRC\src\wsi\sdl3"

    if ($sourceMatches.Count -eq 0) {
        Fail "No SDL3 runtime library-name string was found in the new DXVK SDL3 WSI source."
    }

    Log ""
    Log "SDL3 WSI SOURCE NAMES BEFORE PATCH:"
    foreach ($m in $sourceMatches) {
        Log "  $($m.Name)  <-  $($m.File)"
    }


    Step "3/6 PATCH SDL3 WSI SONAME + INCREMENTAL DXVK REBUILD"

    $changedFiles = @()

    $grouped = $sourceMatches | Group-Object File

    foreach ($g in $grouped) {
        $file = $g.Name
        $text = [IO.File]::ReadAllText($file)
        $original = $text

        # Replace only SDL3 shared-library filename literals.
        # Function names such as SDL_Init are untouched.
        $text = [regex]::Replace(
            $text,
            '(?i)(?:lib)?SDL3(?:\.so(?:\.[0-9]+)*|\.dll)',
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($match)

                if ($match.Value -ceq $desired) {
                    return $match.Value
                }

                return $desired
            }
        )

        if ($text -cne $original) {
            $backup = "$file.before_android_sdl_soname.bak"

            if (!(Test-Path $backup)) {
                [IO.File]::WriteAllText(
                    $backup,
                    $original,
                    (New-Object System.Text.UTF8Encoding($false))
                )
            }

            [IO.File]::WriteAllText(
                $file,
                $text,
                (New-Object System.Text.UTF8Encoding($false))
            )

            $changedFiles += $file
            Log "PATCHED: $file"
        }
    }

    if ($changedFiles.Count -eq 0) {
        # If source already uses the known-good name, stop rather than
        # pretending this fix changes anything.
        Fail "The new DXVK source already uses the same SDL3 soname as the old working runtime. The loader failure has a different cause and needs a different fix."
    }

    $compile = Run-Native -Exe $MESON -ArgumentList @(
        "compile","-C",$DXVKBUILD
    )

    if ($compile.Code -ne 0) {
        Fail "Incremental DXVK rebuild failed after SDL3 soname patch."
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
        Fail "Rebuild succeeded but D3D8/D3D9 outputs were not found."
    }

    $rebuiltNames = Get-SdlNamesFromBinary $built8.FullName

    Log ""
    Log "REBUILT D3D8 SDL3 NAMES:"
    foreach ($n in $rebuiltNames) { Log "  $n" }

    if ($desired -notin $rebuiltNames) {
        Fail "Rebuilt DXVK does not contain the known-good SDL3 soname."
    }

    Log ""
    Log "SDL3 SONAME PATCH BUILD: SUCCESS"


    Step "4/6 REPLACE DXVK ONLY + PACKAGE APK"

    Copy-Item $built8.FullName $CURRENT8 -Force
    Copy-Item $built9.FullName $CURRENT9 -Force

    Log "DXVK D3D8/D3D9 REPLACED"
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


    Step "5/6 INSTALL UPDATE - KEEP GAMEDATA"

    $install = Run-Native -Exe $ADB -ArgumentList @(
        "install","-r","-d",$APK
    )

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "APK update failed. No uninstall was attempted."
    }

    Log "APK UPDATE: SUCCESS"
    Log "NO 2GB RECOPY"


    Step "6/6 LAUNCH + READ THE NEXT REAL RENDER RESULT"

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
    Log "----- ENGINE LAST 300 LINES -----"

    $stderrLines |
        Select-Object -Last 300 |
        ForEach-Object { Log $_.ToString() }

    Log ""
    Log "PID: $gamePid"
    Log "FOREGROUND: $foreground"

    if ($stderrText -match "SDL3 WSI: Failed to load SDL3 DLL") {
        Fail "SDL3 WSI still cannot load SDL3 even after matching the known-good old-runtime soname."
    }

    Log ""
    Log "SDL3 WSI LOADER ERROR: GONE"

    if ($stderrText -match "Required Vulkan extension VK_EXT_robustness2 not supported") {
        Fail "SDL3 is fixed. The next blocker is now confirmed: this DXVK build still requires VK_EXT_robustness2 on the Mali driver."
    }

    if ($stderrText -match "DxvkAdapter: Failed to create device") {
        Fail "SDL3 is fixed, but DXVK device creation failed for a different Vulkan capability. Exact reason is above."
    }

    if ($gamePid -and $foreground) {
        Log ""
        Log "SUCCESS: ZERO HOUR IS ALIVE IN THE FOREGROUND."
        Log "LOOK AT THE PHONE NOW."
        exit 0
    }

    Fail "SDL3 loader was fixed, but Zero Hour is not the resumed foreground activity after 15 seconds. Exact engine end is above."
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" |
        Out-File $LOG -Append -Encoding utf8

    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
