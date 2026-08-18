$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR ANDROID - ONE SCRIPT
# Uses:
#   - current local source/build
#   - current local libmain.so (rebuilt incrementally)
#   - runtime .so/assets from the latest public Android APK
#   - clean game data already prepared on this PC
#
# Creates only ONE user-facing log:
#   C:\Users\DELL\Desktop\ZeroHour_ONE_LOG.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$BUILD = "$ROOT\build\android-vulkan"
$SDK = "$env:LOCALAPPDATA\Android\Sdk"
$NDK = "$SDK\ndk\27.1.12297006"
$JBR = "C:\Program Files\Android\Android Studio\jbr"
$ADB = "$SDK\platform-tools\adb.exe"

$DATA = "C:\Users\DELL\Desktop\ZeroHour_Mobile_Assets"
$LOG = "C:\Users\DELL\Desktop\ZeroHour_ONE_LOG.txt"

$TOOLS = "$ROOT\tools"
$RUNTIME_APK = "$TOOLS\GeneralsZH-runtime.apk"
$GRADLE_HOME = "$TOOLS\gradle-8.7"
$GRADLE_EXE = "$GRADLE_HOME\bin\gradle.bat"
$GRADLE_ZIP = "$TOOLS\gradle-8.7-bin.zip"

$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$ASSETS = "$ROOT\android\app\src\main\assets"
$BUILD_GRADLE = "$ROOT\android\app\build.gradle"
$SDL_MAIN = "$ROOT\GeneralsMD\Code\Main\SDL3Main.cpp"
$LOCAL_APK = "$ROOT\android\app\build\outputs\apk\debug\app-debug.apk"

$REMOTE_DATA = "/storage/emulated/0/Android/data/me.generalsx.zh/files/GameData/Data"

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
    Log ""
    Log "SEND ME ONLY THIS FILE:"
    Log $LOG
    throw $Text
}

try {
    Step "1/9 VERIFY PC + PHONE"

    foreach ($p in @($ROOT,$BUILD,$DATA,$ADB,$SDL_MAIN,$BUILD_GRADLE)) {
        if (!(Test-Path $p)) { Fail "Missing required path: $p" }
    }

    $env:ANDROID_HOME = $SDK
    $env:ANDROID_SDK_ROOT = $SDK
    $env:ANDROID_NDK_HOME = $NDK
    $env:JAVA_HOME = $JBR
    $env:Path = "$JBR\bin;$SDK\platform-tools;$SDK\cmake\3.31.6\bin;C:\Program Files\Git\usr\bin;$env:Path"

    & $ADB start-server | Out-Null

    $devices = & $ADB devices
    $authorized = @(
        $devices | Select-Object -Skip 1 | Where-Object { $_ -match "^\S+\s+device$" }
    )

    if ($authorized.Count -ne 1) {
        Fail "Exactly one authorized Android device is required. Found=$($authorized.Count)"
    }

    $model = (& $ADB shell getprop ro.product.model).Trim()
    $abi = (& $ADB shell getprop ro.product.cpu.abi).Trim()

    Log "DEVICE: $model"
    Log "ABI: $abi"

    if ($abi -notmatch "arm64") {
        Fail "Phone is not arm64-v8a."
    }

    # Validate clean legal game data we already prepared.
    $requiredBigs = @(
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

    $missing = @($requiredBigs | Where-Object { !(Test-Path (Join-Path $DATA $_)) })
    if ($missing.Count -gt 0) {
        Fail "Game data folder is missing: $($missing -join ', ')"
    }

    Log "GAME DATA SOURCE: $DATA"
    Log "GAME DATA: OK"


    Step "2/9 PATCH GAMEDATA CREATION IN CURRENT ENGINE"

    $src = [IO.File]::ReadAllText($SDL_MAIN)

    if ($src -notmatch "V8_ANDROID_GAMEDATA_CREATE") {
        $needle = @'
		if (extFiles != nullptr) {
			char gameData[1024];
			snprintf(gameData, sizeof(gameData), "%s/GameData", extFiles);
'@

        $replacement = @'
		if (extFiles != nullptr) {
			char gameData[1024];
			snprintf(gameData, sizeof(gameData), "%s/GameData", extFiles);

			// V8_ANDROID_GAMEDATA_CREATE
			// Create the app-owned GameData tree from inside the process itself.
			// This avoids Android /sdcard FUSE ownership/visibility differences
			// when the directory was originally created by adb shell.
			mkdir(gameData, 0755);
			{
				char gameDataData[1100];
				snprintf(gameDataData, sizeof(gameDataData), "%s/Data", gameData);
				mkdir(gameDataData, 0755);
			}
'@

        if (!$src.Contains($needle)) {
            Fail "Expected Android GameData block was not found in SDL3Main.cpp. No unsafe patch was made."
        }

        $src = $src.Replace($needle, $replacement)
        [IO.File]::WriteAllText(
            $SDL_MAIN,
            $src,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Log "Applied app-owned GameData creation patch."
    }
    else {
        Log "GameData creation patch already present."
    }


    Step "3/9 REBUILD ONLY THE CURRENT ENGINE INCREMENTALLY"

    $engineBuildLog = & cmake --build $BUILD --target z_generals --parallel 8 2>&1
    $engineBuildLog | ForEach-Object { Log $_.ToString() }

    if ($LASTEXITCODE -ne 0) {
        Fail "Incremental engine build failed."
    }

    $LOCAL_MAIN = "$BUILD\GeneralsMD\Code\Main\libmain.so"

    if (!(Test-Path $LOCAL_MAIN)) {
        $LOCAL_MAIN = Get-ChildItem $BUILD -Recurse -File -Filter "libmain.so" -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending |
            Select-Object -First 1 |
            Select-Object -ExpandProperty FullName
    }

    if (!$LOCAL_MAIN -or !(Test-Path $LOCAL_MAIN)) {
        Fail "Fresh libmain.so not found after successful build."
    }

    $mainSize = [math]::Round((Get-Item $LOCAL_MAIN).Length/1MB,2)
    Log "FRESH libmain.so: $mainSize MB"
    Log $LOCAL_MAIN


    Step "4/9 GET ONE RUNTIME APK AUTOMATICALLY"

    New-Item $TOOLS -ItemType Directory -Force | Out-Null

    if (!(Test-Path $RUNTIME_APK) -or (Get-Item $RUNTIME_APK).Length -lt 50MB) {
        Log "Downloading Android runtime APK from the project's GitHub releases..."

        $headers = @{
            "User-Agent" = "ZeroHour-OneScript"
            "Accept" = "application/vnd.github+json"
        }

        $releases = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/tarek369/GeneralsZH-Android/releases?per_page=10" `
            -Headers $headers

        $asset = $null
        foreach ($release in $releases) {
            $asset = $release.assets |
                Where-Object { $_.name -eq "GeneralsZH-full.apk" } |
                Select-Object -First 1
            if ($asset) {
                Log "USING RELEASE: $($release.tag_name)"
                break
            }
        }

        if (!$asset) {
            Fail "No GeneralsZH-full.apk asset was found in the latest GitHub releases."
        }

        Invoke-WebRequest `
            -Uri $asset.browser_download_url `
            -Headers @{ "User-Agent" = "ZeroHour-OneScript" } `
            -OutFile $RUNTIME_APK
    }

    if ((Get-Item $RUNTIME_APK).Length -lt 50MB) {
        Fail "Runtime APK download is invalid/suspiciously small."
    }

    Log "RUNTIME APK: $([math]::Round((Get-Item $RUNTIME_APK).Length/1MB,2)) MB"


    Step "5/9 STAGE ANDROID RUNTIME + FRESH ENGINE"

    New-Item $JNI -ItemType Directory -Force | Out-Null
    New-Item $ASSETS -ItemType Directory -Force | Out-Null

    # Remove only previously staged .so files from THIS Android packaging directory.
    Get-ChildItem $JNI -File -Filter "*.so" -ErrorAction SilentlyContinue |
        Remove-Item -Force

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($RUNTIME_APK)

    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -like "lib/arm64-v8a/*.so") {
                $name = [IO.Path]::GetFileName($entry.FullName)

                # Never take the old crashing engine from the release APK.
                if ($name -ne "libmain.so") {
                    $dest = Join-Path $JNI $name
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$true)
                }
            }

            if ($entry.FullName.StartsWith("assets/") -and !$entry.FullName.EndsWith("/")) {
                $relative = $entry.FullName.Substring(7)
                $dest = Join-Path $ASSETS ($relative -replace "/","\")
                New-Item (Split-Path $dest -Parent) -ItemType Directory -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$true)
            }
        }
    }
    finally {
        $zip.Dispose()
    }

    Copy-Item $LOCAL_MAIN (Join-Path $JNI "libmain.so") -Force

    $mustHave = @(
        "libmain.so",
        "libSDL3.so",
        "libopenal.so",
        "libdxvk_d3d8.so"
    )

    foreach ($name in $mustHave) {
        if (!(Test-Path (Join-Path $JNI $name))) {
            Fail "Required APK runtime library is missing: $name"
        }
    }

    Log "JNI RUNTIME READY:"
    Get-ChildItem $JNI -File -Filter "*.so" |
        Sort-Object Name |
        ForEach-Object {
            Log ("  {0,-28} {1,8} MB" -f $_.Name,[math]::Round($_.Length/1MB,2))
        }


    Step "6/9 FIX ANDROID PACKAGING + GET GRADLE"

    $bg = [IO.File]::ReadAllText($BUILD_GRADLE)
    $fixedBg = $bg.Replace(
        "../../build/android-game/_deps/sdl3-src/android-project/app/src/main/java",
        "../../build/android-vulkan/_deps/sdl3-src/android-project/app/src/main/java"
    )

    if ($fixedBg -ne $bg) {
        [IO.File]::WriteAllText(
            $BUILD_GRADLE,
            $fixedBg,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Log "Fixed stale SDL Java source path."
    }

    $sdkEscaped = $SDK.Replace("\","\\").Replace(":","\:")
    "sdk.dir=$sdkEscaped" | Out-File "$ROOT\android\local.properties" -Encoding ascii

    if (!(Test-Path $GRADLE_EXE)) {
        if (!(Test-Path $GRADLE_ZIP) -or (Get-Item $GRADLE_ZIP).Length -lt 50MB) {
            Log "Downloading Gradle 8.7 once..."
            Invoke-WebRequest `
                -Uri "https://services.gradle.org/distributions/gradle-8.7-bin.zip" `
                -OutFile $GRADLE_ZIP
        }

        Log "Extracting Gradle 8.7..."
        Expand-Archive $GRADLE_ZIP $TOOLS -Force
    }

    if (!(Test-Path $GRADLE_EXE)) {
        Fail "Gradle 8.7 is unavailable."
    }


    Step "7/9 BUILD + INSTALL NEW APK"

    $gradleOutput = & $GRADLE_EXE `
        -p "$ROOT\android" `
        :app:assembleDebug `
        -PSAGE_SKIP_NATIVE_BUILD=true `
        --no-daemon `
        --stacktrace `
        2>&1

    $gradleOutput | ForEach-Object { Log $_.ToString() }

    if ($LASTEXITCODE -ne 0) {
        Fail "Gradle APK build failed."
    }

    if (!(Test-Path $LOCAL_APK)) {
        Fail "app-debug.apk was not produced."
    }

    Log "LOCAL APK: $([math]::Round((Get-Item $LOCAL_APK).Length/1MB,2)) MB"

    $install = (& $ADB install -r -d $LOCAL_APK 2>&1 | Out-String)
    Log $install

    $didUninstall = $false

    if ($install -notmatch "Success") {
        if ($install -match "UPDATE_INCOMPATIBLE|signature|signatures") {
            Log "Old APK signature differs. Replacing old package..."
            & $ADB uninstall me.generalsx.zh 2>&1 | ForEach-Object { Log $_.ToString() }
            $didUninstall = $true

            $install = (& $ADB install $LOCAL_APK 2>&1 | Out-String)
            Log $install
        }
    }

    if ($install -notmatch "Success") {
        Fail "New local APK installation failed."
    }

    Log "NEW APK INSTALLED."


    Step "8/9 CREATE APP-OWNED GAMEDATA + COPY CLEAN DATA"

    # Launch once. The fresh C++ engine creates GameData/Data as the APP UID
    # before it tries to use the directory.
    & $ADB logcat -c | Out-Null
    & $ADB shell am start -n me.generalsx.zh/.GameActivity | Out-Null
    Start-Sleep -Seconds 2
    & $ADB shell am force-stop me.generalsx.zh | Out-Null

    $remoteList = @(& $ADB shell "ls -1 '$REMOTE_DATA'" 2>$null)
    $remoteMissing = @($requiredBigs | Where-Object { $remoteList -notcontains $_ })

    # Always restore if data is missing (e.g. after signature-uninstall).
    if ($remoteMissing.Count -gt 0) {
        Log "Copying clean game data to phone..."
        $allBigs = @(Get-ChildItem $DATA -File -Filter "*.big" | Sort-Object Name)

        foreach ($f in $allBigs) {
            Log "PUSH: $($f.Name)"
            & $ADB push $f.FullName "$REMOTE_DATA/$($f.Name)" |
                ForEach-Object { Write-Host $_ }

            if ($LASTEXITCODE -ne 0) {
                Fail "adb push failed: $($f.Name)"
            }
        }
    }
    else {
        Log "Existing game data is already present; skipping the 1.9 GB copy."
    }

    $remoteList = @(& $ADB shell "ls -1 '$REMOTE_DATA'" 2>$null)
    $remoteMissing = @($requiredBigs | Where-Object { $remoteList -notcontains $_ })

    if ($remoteMissing.Count -gt 0) {
        Fail "Phone data verification failed: $($remoteMissing -join ', ')"
    }

    Log "PHONE GAMEDATA VERIFIED."


    Step "9/9 LAUNCH ZERO HOUR"

    & $ADB shell am force-stop me.generalsx.zh | Out-Null
    & $ADB logcat -c | Out-Null

    $launch = (& $ADB shell am start -n me.generalsx.zh/.GameActivity 2>&1 | Out-String).Trim()
    Log $launch

    Start-Sleep -Seconds 30

    $gamePid = (& $ADB shell pidof me.generalsx.zh 2>$null | Out-String).Trim()

    $runtime = & $ADB logcat -d -v time

    Log ""
    Log "----- IMPORTANT ANDROID RUNTIME -----"

    $runtime |
        Select-String -Pattern "GeneralsX|SDL_main|GameData|CWD|Scudo|SIGABRT|SIGSEGV|Fatal signal|libmain|DXVK|Vulkan|Mali|OpenAL|Oboe|AAudio|AndroidRuntime" |
        Select-Object -Last 300 |
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

    Log "THE GAME STARTED BUT STOPPED/CRASHED."
    Log "SEND ME ONLY:"
    Log $LOG
    Log "============================================================"
    exit 2
}
catch {
    "`r`nEXCEPTION:`r`n$($_ | Out-String)" | Out-File $LOG -Append -Encoding utf8
    Write-Host ""
    Write-Host "Stopped. Send me only:"
    Write-Host $LOG
    exit 1
}
