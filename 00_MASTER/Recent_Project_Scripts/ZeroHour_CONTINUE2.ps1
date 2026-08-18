$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ZERO HOUR ANDROID - CONTINUE 2
# Fixes the ADB invocation bug from the previous script.
# Starts from the already-built APK; does NOT rebuild the engine or Gradle package
# unless the APK is missing.

$ROOT  = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$SDK   = "$env:LOCALAPPDATA\Android\Sdk"
$JBR   = "C:\Program Files\Android\Android Studio\jbr"
$ADB   = "$SDK\platform-tools\adb.exe"

$DATA  = "C:\Users\DELL\Desktop\ZeroHour_Mobile_Assets"
$LOG   = "C:\Users\DELL\Desktop\ZeroHour_ONE_LOG.txt"

$NEWAPK = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"
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

# IMPORTANT: do NOT name this parameter $Args.
# $args is a special PowerShell automatic variable.
function Run-Adb {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$ArgumentList
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $output = & $ADB @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    $textLines = @()
    foreach ($item in @($output)) {
        if ($null -ne $item) {
            $line = $item.ToString()
            $textLines += $line
            Log $line
        }
    }

    return [pscustomobject]@{
        Code = $code
        Text = ($textLines -join "`r`n")
    }
}

try {
    Step "1/4 VERIFY READY APK + PHONE"

    foreach ($p in @($ADB,$DATA,$NEWAPK)) {
        if (!(Test-Path $p)) {
            Fail "Missing required path: $p"
        }
    }

    $env:JAVA_HOME = $JBR
    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:Path = "$JBR\bin;$SDK\platform-tools;$env:Path"

    $startServer = Run-Adb -ArgumentList @("start-server")

    $devicesRaw = & $ADB devices
    $authorized = @(
        $devicesRaw |
        Select-Object -Skip 1 |
        Where-Object { $_ -match "^\S+\s+device$" }
    )

    if ($authorized.Count -ne 1) {
        Fail "Exactly one authorized Android device is required. Found=$($authorized.Count)"
    }

    $model = (& $ADB shell getprop ro.product.model).Trim()
    $abi   = (& $ADB shell getprop ro.product.cpu.abi).Trim()

    Log "DEVICE: $model"
    Log "ABI: $abi"
    Log "READY APK: $NEWAPK"
    Log "APK SIZE: $([math]::Round((Get-Item $NEWAPK).Length/1MB,2)) MB"

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

    $missingPC = @(
        $required | Where-Object { !(Test-Path (Join-Path $DATA $_)) }
    )

    if ($missingPC.Count -gt 0) {
        Fail "PC game data incomplete: $($missingPC -join ', ')"
    }

    Log "PC GAME DATA: OK"


    Step "2/4 INSTALL THE NEW LOCAL APK"

    $install = Run-Adb -ArgumentList @("install","-r","-d",$NEWAPK)

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        if ($install.Text -match "UPDATE_INCOMPATIBLE|signature|signatures|VERSION_DOWNGRADE") {
            Log ""
            Log "OLD APK CANNOT BE UPDATED IN PLACE -> CLEAN REPLACE"

            $uninstall = Run-Adb -ArgumentList @("uninstall","me.generalsx.zh")

            # uninstall can legitimately say unknown package if package vanished already
            if ($uninstall.Code -ne 0 -and $uninstall.Text -notmatch "Unknown package") {
                Fail "Could not remove old package."
            }

            $install = Run-Adb -ArgumentList @("install",$NEWAPK)
        }
    }

    if ($install.Code -ne 0 -or $install.Text -notmatch "Success") {
        Fail "New local APK installation failed."
    }

    Log "NEW LOCAL APK: INSTALLED"

    $runAs = Run-Adb -ArgumentList @("shell","run-as","me.generalsx.zh","pwd")

    if ($runAs.Code -ne 0 -or $runAs.Text -notmatch "me.generalsx.zh") {
        Fail "The new APK installed, but run-as is unavailable."
    }

    Log "RUN-AS: OK"


    Step "3/4 PUT GAMEDATA WHERE THE APP ITSELF CAN READ IT"

    $mk = Run-Adb -ArgumentList @(
        "shell","run-as","me.generalsx.zh",
        "mkdir","-p",$REMOTE_REL
    )

    if ($mk.Code -ne 0) {
        Fail "Could not create internal GameData/Data."
    }

    $listBefore = Run-Adb -ArgumentList @(
        "shell","run-as","me.generalsx.zh",
        "ls","-1",$REMOTE_REL
    )

    $insideBefore = @(
        $listBefore.Text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )

    $missingInside = @(
        $required | Where-Object { $insideBefore -notcontains $_ }
    )

    if ($missingInside.Count -gt 0) {
        Log "INTERNAL DATA IS MISSING -> COPYING CLEAN DATA"

        Run-Adb -ArgumentList @("shell","rm","-rf",$REMOTE_TMP) | Out-Null
        $mkTmp = Run-Adb -ArgumentList @("shell","mkdir","-p",$REMOTE_TMP)

        if ($mkTmp.Code -ne 0) {
            Fail "Could not create temporary phone folder."
        }

        $allBigs = @(
            Get-ChildItem $DATA -File -Filter "*.big" |
            Sort-Object Name
        )

        foreach ($f in $allBigs) {
            Log ""
            Log "COPY: $($f.Name)"

            $tmp = "$REMOTE_TMP/$($f.Name)"

            $push = Run-Adb -ArgumentList @(
                "push",$f.FullName,$tmp
            )

            if ($push.Code -ne 0) {
                Fail "adb push failed: $($f.Name)"
            }

            $chmod = Run-Adb -ArgumentList @(
                "shell","chmod","644",$tmp
            )

            if ($chmod.Code -ne 0) {
                Fail "chmod failed: $($f.Name)"
            }

            $copy = Run-Adb -ArgumentList @(
                "shell","run-as","me.generalsx.zh",
                "cp",$tmp,"$REMOTE_REL/$($f.Name)"
            )

            if ($copy.Code -ne 0) {
                Fail "run-as copy failed: $($f.Name)"
            }

            Run-Adb -ArgumentList @("shell","rm","-f",$tmp) | Out-Null
        }

        Run-Adb -ArgumentList @("shell","rm","-rf",$REMOTE_TMP) | Out-Null
    }
    else {
        Log "INTERNAL GAME DATA ALREADY COMPLETE -> NO 1.9 GB RECOPY"
    }

    $listAfter = Run-Adb -ArgumentList @(
        "shell","run-as","me.generalsx.zh",
        "ls","-1",$REMOTE_REL
    )

    $insideAfter = @(
        $listAfter.Text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
    )

    $missingAfter = @(
        $required | Where-Object { $insideAfter -notcontains $_ }
    )

    if ($missingAfter.Count -gt 0) {
        Fail "Internal GameData verification failed: $($missingAfter -join ', ')"
    }

    Log "INTERNAL GAMEDATA: VERIFIED"


    Step "4/4 LAUNCH ZERO HOUR + CAPTURE REAL RESULT"

    Run-Adb -ArgumentList @(
        "shell","am","force-stop","me.generalsx.zh"
    ) | Out-Null

    Run-Adb -ArgumentList @("logcat","-c") | Out-Null

    $start = Run-Adb -ArgumentList @(
        "shell","am","start","-n",
        "me.generalsx.zh/.GameActivity"
    )

    Start-Sleep -Seconds 30

    $pidResult = Run-Adb -ArgumentList @(
        "shell","pidof","me.generalsx.zh"
    )

    $gamePid = $pidResult.Text.Trim()

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $runtime = & $ADB logcat -d -v time 2>&1
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    Log ""
    Log "----- IMPORTANT RUNTIME -----"

    $runtime |
        Select-String -Pattern "GeneralsX|SDL_main|storage:|GameData|CWD|Scudo|SIGABRT|SIGSEGV|Fatal signal|libmain|DXVK|Vulkan|Mali|OpenAL|Oboe|AAudio|AndroidRuntime" |
        Select-Object -Last 400 |
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
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" |
        Out-File $LOG -Append -Encoding utf8

    Write-Host ""
    Write-Host "STOPPED. Send me only:"
    Write-Host $LOG
    exit 1
}
