$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR ANDROID - CONTINUE FROM GRADLE
# One script, one log.
# Resumes after the successful fresh libmain.so build.
# ============================================================

$ROOT  = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$BUILD = "$ROOT\build\android-vulkan"
$SDK   = "$env:LOCALAPPDATA\Android\Sdk"
$JBR   = "C:\Program Files\Android\Android Studio\jbr"
$ADB   = "$SDK\platform-tools\adb.exe"

$DATA  = "C:\Users\DELL\Desktop\ZeroHour_Mobile_Assets"
$LOG   = "C:\Users\DELL\Desktop\ZeroHour_ONE_LOG.txt"

$TOOLS      = "$ROOT\tools"
$JNI        = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$GRADLEEXE  = "$TOOLS\gradle-8.7\bin\gradle.bat"
$NEWAPK     = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"
$LOCALMAIN  = "$BUILD\GeneralsMD\Code\Main\libmain.so"

$REMOTE_TMP = "/data/local/tmp/zerohour_one"
$REMOTE_REL = "files/GameData/Data"

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

function RunNative([string]$Exe, [string[]]$Args) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $lines = & $Exe @Args 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
    }

    foreach ($line in @($lines)) {
        if ($null -ne $line) {
            Log $line.ToString()
        }
    }

    return [pscustomobject]@{
        Code = $code
        Text = ($lines | Out-String)
    }
}

try {
    Step "1/5 VERIFY READY STATE"

    foreach ($p in @($ROOT,$ADB,$DATA,$GRADLEEXE,$LOCALMAIN,$JNI)) {
        if (!(Test-Path $p)) {
            Fail "Missing required ready-state path: $p"
        }
    }

    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:JAVA_HOME = $JBR
    $env:Path = "$JBR\bin;$SDK\platform-tools;$env:Path"

    & $ADB start-server | Out-Null

    $dev = & $ADB devices
    $ok = @($dev | Select-Object -Skip 1 | Where-Object { $_ -match "^\S+\s+device$" })

    if ($ok.Count -ne 1) {
        Fail "Exactly one authorized Android device is required. Found=$($ok.Count)"
    }

    Log "DEVICE: $((& $ADB shell getprop ro.product.model).Trim())"
    Log "ABI: $((& $ADB shell getprop ro.product.cpu.abi).Trim())"
    Log "FRESH ENGINE: $([math]::Round((Get-Item $LOCALMAIN).Length/1MB,2)) MB"

    foreach ($name in @("libmain.so","libSDL3.so","libopenal.so","libdxvk_d3d8.so")) {
        $p = Join-Path $JNI $name
        if (!(Test-Path $p)) {
            Fail "Staged runtime library missing: $name"
        }
    }

    Log "RUNTIME LIBRARIES: READY"


    Step "2/5 PACKAGE APK WITH GRADLE"

    $sdkEscaped = $SDK.Replace("\","\\").Replace(":","\:")
    "sdk.dir=$sdkEscaped" | Out-File "$ROOT\android\local.properties" -Encoding ascii

    $gradleArgs = @(
        "-p", "$ROOT\android",
        ":app:assembleDebug",
        "-PSAGE_SKIP_NATIVE_BUILD=true",
        "--no-daemon",
        "--stacktrace"
    )

    # IMPORTANT:
    # Gradle writes harmless deprecation notes/warnings to stderr.
    # PowerShell 5.1 can wrap those as NativeCommandError when
    # ErrorActionPreference=Stop. RunNative deliberately prevents that.
    $gr = RunNative $GRADLEEXE $gradleArgs

    if ($gr.Code -ne 0) {
        Fail "Gradle returned exit code $($gr.Code)."
    }

    if (!(Test-Path $NEWAPK)) {
        Fail "Gradle succeeded but app-debug.apk was not produced."
    }

    Log ""
    Log "APK BUILD SUCCESS"
    Log "APK: $NEWAPK"
    Log "SIZE: $([math]::Round((Get-Item $NEWAPK).Length/1MB,2)) MB"


    Step "3/5 INSTALL NEW APK"

    $ins = RunNative $ADB @("install","-r","-d",$NEWAPK)

    if ($ins.Code -ne 0 -or $ins.Text -notmatch "Success") {
        if ($ins.Text -match "UPDATE_INCOMPATIBLE|signature|signatures") {
            Log "OLD APK SIGNATURE DIFFERS -> REPLACING PACKAGE"

            $un = RunNative $ADB @("uninstall","me.generalsx.zh")
            if ($un.Code -ne 0) {
                Fail "Could not uninstall old APK."
            }

            $ins = RunNative $ADB @("install",$NEWAPK)
        }
    }

    if ($ins.Code -ne 0 -or $ins.Text -notmatch "Success") {
        Fail "New local APK installation failed."
    }

    Log "NEW DEBUG APK INSTALLED"

    $ra = RunNative $ADB @("shell","run-as","me.generalsx.zh","pwd")

    if ($ra.Code -ne 0 -or $ra.Text -notmatch "me.generalsx.zh") {
        Fail "run-as is not available for the new debug APK."
    }

    Log "RUN-AS: OK"


    Step "4/5 COPY GAME DATA TO INTERNAL APP STORAGE"

    $required = @(
        "INI.big","INIZH.big",
        "Textures.big","TexturesZH.big",
        "Audio.big","AudioZH.big",
        "Music.big","MusicZH.big",
        "MapsZH.big",
        "Terrain.big","TerrainZH.big",
        "W3D.big","W3DZH.big",
        "English.big","EnglishZH.big",
        "Window.big","WindowZH.big",
        "ShadersZH.big"
    )

    $missingPC = @($required | Where-Object { !(Test-Path (Join-Path $DATA $_)) })
    if ($missingPC.Count -gt 0) {
        Fail "PC game data incomplete: $($missingPC -join ', ')"
    }

    $mk = RunNative $ADB @("shell","run-as","me.generalsx.zh","mkdir","-p",$REMOTE_REL)
    if ($mk.Code -ne 0) {
        Fail "Could not create internal GameData/Data."
    }

    $insideBefore = RunNative $ADB @("shell","run-as","me.generalsx.zh","ls","-1",$REMOTE_REL)
    $insideNames = @(
        $insideBefore.Text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )

    $missingInside = @($required | Where-Object { $insideNames -notcontains $_ })

    if ($missingInside.Count -gt 0) {
        Log "INTERNAL DATA IS MISSING -> COPYING CLEAN GAME DATA"

        $rm = RunNative $ADB @("shell","rm","-rf",$REMOTE_TMP)
        $mkTmp = RunNative $ADB @("shell","mkdir","-p",$REMOTE_TMP)

        $files = @(Get-ChildItem $DATA -File -Filter "*.big" | Sort-Object Name)

        foreach ($f in $files) {
            $tmp = "$REMOTE_TMP/$($f.Name)"

            Log "COPY: $($f.Name)"

            $push = RunNative $ADB @("push",$f.FullName,$tmp)
            if ($push.Code -ne 0) {
                Fail "adb push failed: $($f.Name)"
            }

            $chmod = RunNative $ADB @("shell","chmod","644",$tmp)
            if ($chmod.Code -ne 0) {
                Fail "chmod failed: $($f.Name)"
            }

            $copy = RunNative $ADB @(
                "shell","run-as","me.generalsx.zh",
                "cp",$tmp,"$REMOTE_REL/$($f.Name)"
            )

            if ($copy.Code -ne 0) {
                Fail "run-as copy failed: $($f.Name)"
            }

            RunNative $ADB @("shell","rm","-f",$tmp) | Out-Null
        }

        RunNative $ADB @("shell","rm","-rf",$REMOTE_TMP) | Out-Null
    }
    else {
        Log "INTERNAL GAME DATA ALREADY PRESENT -> SKIPPING 1.9 GB COPY"
    }

    $insideAfter = RunNative $ADB @("shell","run-as","me.generalsx.zh","ls","-1",$REMOTE_REL)

    $insideNames = @(
        $insideAfter.Text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )

    $missingInside = @($required | Where-Object { $insideNames -notcontains $_ })

    if ($missingInside.Count -gt 0) {
        Fail "Internal GameData verification failed: $($missingInside -join ', ')"
    }

    Log "INTERNAL GAMEDATA: VERIFIED"


    Step "5/5 LAUNCH ZERO HOUR"

    RunNative $ADB @("shell","am","force-stop","me.generalsx.zh") | Out-Null
    RunNative $ADB @("logcat","-c") | Out-Null

    $start = RunNative $ADB @(
        "shell","am","start","-n","me.generalsx.zh/.GameActivity"
    )

    Start-Sleep -Seconds 30

    $pidCheck = RunNative $ADB @("shell","pidof","me.generalsx.zh")
    $gamePid = $pidCheck.Text.Trim()

    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $runtime = & $ADB logcat -d -v time 2>&1
    }
    finally {
        $ErrorActionPreference = $old
    }

    Log ""
    Log "----- IMPORTANT RUNTIME -----"

    $runtime |
        Select-String -Pattern "GeneralsX|SDL_main|storage:|GameData|CWD|Scudo|SIGABRT|SIGSEGV|Fatal signal|libmain|DXVK|Vulkan|Mali|OpenAL|Oboe|AAudio|AndroidRuntime" |
        Select-Object -Last 350 |
        ForEach-Object { Log $_.Line }

    Log ""
    Log "============================================================"

    if ($gamePid) {
        Log "SUCCESS: ZERO HOUR IS RUNNING"
        Log "PID: $gamePid"
        Log "LOOK AT THE PHONE NOW."
        Log "============================================================"
        exit 0
    }

    Log "GAME CRASHED OR EXITED."
    Log "SEND ME ONLY:"
    Log $LOG
    Log "============================================================"
    exit 2
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" | Out-File $LOG -Append -Encoding utf8
    Write-Host ""
    Write-Host "STOPPED. Send me only:"
    Write-Host $LOG
    exit 1
}
