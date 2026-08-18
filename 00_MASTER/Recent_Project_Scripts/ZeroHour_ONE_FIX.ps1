$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR ANDROID - ONE SCRIPT FIX
#
# IMPORTANT:
# - No new work folders are created.
# - One log only: C:\Users\DELL\Desktop\ZeroHour_ONE_LOG.txt
# - Uses the existing project and existing clean game data.
# - Pulls the already-installed APK from the phone for runtime libraries.
# ============================================================

$ROOT  = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$BUILD = "$ROOT\build\android-vulkan"
$SDK   = "$env:LOCALAPPDATA\Android\Sdk"
$NDK   = "$SDK\ndk\27.1.12297006"
$JBR   = "C:\Program Files\Android\Android Studio\jbr"
$ADB   = "$SDK\platform-tools\adb.exe"

$DATA  = "C:\Users\DELL\Desktop\ZeroHour_Mobile_Assets"
$LOG   = "C:\Users\DELL\Desktop\ZeroHour_ONE_LOG.txt"

$TOOLS       = "$ROOT\tools"
$PULLED_APK  = "$TOOLS\GeneralsZH-installed-runtime.apk"
$JNI         = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$ASSETS      = "$ROOT\android\app\src\main\assets"
$BUILDGRADLE = "$ROOT\android\app\build.gradle"
$SDLMAIN     = "$ROOT\GeneralsMD\Code\Main\SDL3Main.cpp"

$GRADLEHOME  = "$TOOLS\gradle-8.7"
$GRADLEEXE   = "$GRADLEHOME\bin\gradle.bat"
$GRADLEZIP   = "$TOOLS\gradle-8.7-bin.zip"
$NEWAPK      = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"

$REMOTE_TMP  = "/data/local/tmp/zerohour_one"
$REMOTE_REL  = "files/GameData/Data"

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

try {
    Step "1/8 VERIFY EVERYTHING"

    foreach ($p in @($ROOT,$BUILD,$DATA,$ADB,$SDLMAIN,$BUILDGRADLE)) {
        if (!(Test-Path $p)) {
            Fail "Missing: $p"
        }
    }

    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:ANDROID_NDK_HOME = $NDK
    $env:JAVA_HOME = $JBR
    $env:Path = "$JBR\bin;$SDK\platform-tools;$SDK\cmake\3.31.6\bin;C:\Program Files\Git\usr\bin;$env:Path"

    & $ADB start-server | Out-Null

    $dev = & $ADB devices
    $ok = @($dev | Select-Object -Skip 1 | Where-Object { $_ -match "^\S+\s+device$" })

    if ($ok.Count -ne 1) {
        Fail "Exactly one authorized Android device is required. Found=$($ok.Count)"
    }

    Log "DEVICE: $((& $ADB shell getprop ro.product.model).Trim())"
    Log "ABI: $((& $ADB shell getprop ro.product.cpu.abi).Trim())"

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

    $missing = @($required | Where-Object { !(Test-Path (Join-Path $DATA $_)) })
    if ($missing.Count -gt 0) {
        Fail "Clean game data is incomplete: $($missing -join ', ')"
    }

    Log "GAME DATA: OK"


    Step "2/8 FIX THE REAL SCUDO CRASH IN SDL3Main.cpp"

    $src = [IO.File]::ReadAllText($SDLMAIN)

    # SDL_GetAndroidExternalStoragePath(), SDL_GetAndroidInternalStoragePath()
    # and SDL_GetAndroidCachePath() return const SDL-owned paths.
    # The current Android port incorrectly SDL_free()s these returned pointers.
    # The phone crash happens immediately at the first such deallocation.
    $badFrees = @(
        'SDL_free((void*)extFiles);',
        'SDL_free((void*)extFiles2);',
        'SDL_free((void*)intFiles2);',
        'SDL_free((void*)cache);',
        'SDL_free((void*)files);'
    )

    $changed = 0

    foreach ($bad in $badFrees) {
        if ($src.Contains($bad)) {
            $src = $src.Replace($bad, '/* ZEROHOUR_ANDROID_FIX: SDL-owned path; do not free */')
            $changed++
        }
    }

    if ($src -notmatch "ZEROHOUR_ANDROID_FIX") {
        Fail "Expected invalid SDL path frees were not found. Source was left untouched."
    }

    # Make the Android path logic strongly prefer internal app storage.
    # We will copy GameData there as the app UID, avoiding Android 16 external
    # app-data/FUSE visibility differences entirely.
    $externalFirst = @'
		const char *extFiles = SDL_GetAndroidExternalStoragePath();
		const char *files = SDL_GetAndroidInternalStoragePath();
'@

    $internalFirst = @'
		const char *extFiles = SDL_GetAndroidExternalStoragePath();
		const char *files = SDL_GetAndroidInternalStoragePath();
'@

    # No textual change needed here: the existing code already falls back to
    # internal storage. The important part is that internal GameData will exist.

    [IO.File]::WriteAllText(
        $SDLMAIN,
        $src,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Log "INVALID SDL_free CALLS REMOVED THIS RUN: $changed"
    Log "SCUDO PATH-LIFETIME FIX: APPLIED"


    Step "3/8 REBUILD ONLY CHANGED ENGINE CODE"

    $buildOutput = & cmake --build $BUILD --target z_generals --parallel 8 2>&1
    $buildOutput | ForEach-Object { Log $_.ToString() }

    if ($LASTEXITCODE -ne 0) {
        Fail "Incremental engine rebuild failed."
    }

    $LOCALMAIN = "$BUILD\GeneralsMD\Code\Main\libmain.so"

    if (!(Test-Path $LOCALMAIN)) {
        $LOCALMAIN = Get-ChildItem $BUILD -Recurse -File -Filter "libmain.so" -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending |
            Select-Object -First 1 |
            Select-Object -ExpandProperty FullName
    }

    if (!$LOCALMAIN -or !(Test-Path $LOCALMAIN)) {
        Fail "Fresh libmain.so not found."
    }

    Log "FRESH ENGINE: $([math]::Round((Get-Item $LOCALMAIN).Length/1MB,2)) MB"


    Step "4/8 PULL INSTALLED APK + REUSE ITS ANDROID RUNTIME"

    New-Item $TOOLS -ItemType Directory -Force | Out-Null

    $pm = (& $ADB shell pm path me.generalsx.zh | Out-String).Trim()
    if ($pm -notmatch "package:(.+)") {
        Fail "Installed me.generalsx.zh APK was not found on phone."
    }

    $deviceApk = $Matches[1].Trim()

    Log "PULLING INSTALLED APK FROM PHONE..."
    & $ADB pull $deviceApk $PULLED_APK | ForEach-Object { Log $_.ToString() }

    if ($LASTEXITCODE -ne 0 -or !(Test-Path $PULLED_APK)) {
        Fail "Could not pull installed APK."
    }

    Log "PULLED APK: $([math]::Round((Get-Item $PULLED_APK).Length/1MB,2)) MB"

    New-Item $JNI -ItemType Directory -Force | Out-Null
    New-Item $ASSETS -ItemType Directory -Force | Out-Null

    Get-ChildItem $JNI -File -Filter "*.so" -ErrorAction SilentlyContinue |
        Remove-Item -Force

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($PULLED_APK)

    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -like "lib/arm64-v8a/*.so") {
                $name = [IO.Path]::GetFileName($entry.FullName)

                if ($name -ne "libmain.so") {
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
                        $entry,
                        (Join-Path $JNI $name),
                        $true
                    )
                }
            }

            if ($entry.FullName.StartsWith("assets/") -and !$entry.FullName.EndsWith("/")) {
                $rel = $entry.FullName.Substring(7)
                $dest = Join-Path $ASSETS ($rel -replace "/","\")
                New-Item (Split-Path $dest -Parent) -ItemType Directory -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$true)
            }
        }
    }
    finally {
        $zip.Dispose()
    }

    Copy-Item $LOCALMAIN (Join-Path $JNI "libmain.so") -Force

    foreach ($name in @("libmain.so","libSDL3.so","libopenal.so","libdxvk_d3d8.so")) {
        if (!(Test-Path (Join-Path $JNI $name))) {
            Fail "Runtime library missing: $name"
        }
    }

    Log "RUNTIME LIBRARIES READY"


    Step "5/8 PACKAGE NEW APK"

    # Fix the stale SDL3 Java source path in this Windows build.
    $bg = [IO.File]::ReadAllText($BUILDGRADLE)
    $bg2 = $bg.Replace(
        "../../build/android-game/_deps/sdl3-src/android-project/app/src/main/java",
        "../../build/android-vulkan/_deps/sdl3-src/android-project/app/src/main/java"
    )

    if ($bg2 -ne $bg) {
        [IO.File]::WriteAllText(
            $BUILDGRADLE,
            $bg2,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Log "SDL3 JAVA PATH: FIXED"
    }

    $sdkEscaped = $SDK.Replace("\","\\").Replace(":","\:")
    "sdk.dir=$sdkEscaped" | Out-File "$ROOT\android\local.properties" -Encoding ascii

    if (!(Test-Path $GRADLEEXE)) {
        if (!(Test-Path $GRADLEZIP) -or (Get-Item $GRADLEZIP).Length -lt 50MB) {
            Log "DOWNLOADING GRADLE 8.7..."
            Invoke-WebRequest `
                -Uri "https://services.gradle.org/distributions/gradle-8.7-bin.zip" `
                -OutFile $GRADLEZIP
        }

        Log "EXTRACTING GRADLE 8.7..."
        Expand-Archive $GRADLEZIP $TOOLS -Force
    }

    if (!(Test-Path $GRADLEEXE)) {
        Fail "Gradle 8.7 unavailable."
    }

    $gradleOutput = & $GRADLEEXE `
        -p "$ROOT\android" `
        :app:assembleDebug `
        -PSAGE_SKIP_NATIVE_BUILD=true `
        --no-daemon `
        2>&1

    $gradleOutput | ForEach-Object { Log $_.ToString() }

    if ($LASTEXITCODE -ne 0) {
        Fail "Gradle APK packaging failed."
    }

    if (!(Test-Path $NEWAPK)) {
        Fail "New APK was not produced."
    }

    Log "NEW APK: $([math]::Round((Get-Item $NEWAPK).Length/1MB,2)) MB"


    Step "6/8 INSTALL NEW APK"

    $install = (& $ADB install -r -d $NEWAPK 2>&1 | Out-String)
    Log $install

    if ($install -notmatch "Success") {
        if ($install -match "UPDATE_INCOMPATIBLE|signature|signatures") {
            Log "SIGNATURE CHANGED -> REPLACING OLD APK"
            & $ADB uninstall me.generalsx.zh 2>&1 | ForEach-Object { Log $_.ToString() }

            $install = (& $ADB install $NEWAPK 2>&1 | Out-String)
            Log $install
        }
    }

    if ($install -notmatch "Success") {
        Fail "Local APK installation failed."
    }

    # Debug APK must support run-as.
    $runAsTest = (& $ADB shell run-as me.generalsx.zh pwd 2>&1 | Out-String).Trim()
    Log "RUN-AS: $runAsTest"

    if ($runAsTest -notmatch "me.generalsx.zh") {
        Fail "run-as is unavailable for the new debug APK."
    }


    Step "7/8 COPY GAMEDATA INTO INTERNAL APP STORAGE"

    # This completely bypasses Android 16 external app-data visibility.
    & $ADB shell "rm -rf '$REMOTE_TMP'; mkdir -p '$REMOTE_TMP'" | Out-Null
    & $ADB shell run-as me.generalsx.zh mkdir -p $REMOTE_REL | Out-Null

    $allBigs = @(Get-ChildItem $DATA -File -Filter "*.big" | Sort-Object Name)

    foreach ($f in $allBigs) {
        $tmp = "$REMOTE_TMP/$($f.Name)"

        Log "COPY: $($f.Name)"

        & $ADB push $f.FullName $tmp | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail "adb push failed: $($f.Name)"
        }

        & $ADB shell chmod 644 $tmp | Out-Null

        & $ADB shell run-as me.generalsx.zh cp $tmp "$REMOTE_REL/$($f.Name)" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail "run-as copy failed: $($f.Name)"
        }

        & $ADB shell rm -f $tmp | Out-Null
    }

    & $ADB shell rm -rf $REMOTE_TMP | Out-Null

    $inside = @(& $ADB shell run-as me.generalsx.zh ls -1 $REMOTE_REL 2>$null)
    $missingInside = @($required | Where-Object { $inside -notcontains $_ })

    if ($missingInside.Count -gt 0) {
        Fail "Internal GameData verification failed: $($missingInside -join ', ')"
    }

    Log "INTERNAL GAMEDATA: VERIFIED"


    Step "8/8 LAUNCH ZERO HOUR"

    & $ADB shell am force-stop me.generalsx.zh | Out-Null
    & $ADB logcat -c | Out-Null

    $start = (& $ADB shell am start -n me.generalsx.zh/.GameActivity 2>&1 | Out-String).Trim()
    Log $start

    Start-Sleep -Seconds 30

    $gamePid = (& $ADB shell pidof me.generalsx.zh 2>$null | Out-String).Trim()
    $runtime = & $ADB logcat -d -v time

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
