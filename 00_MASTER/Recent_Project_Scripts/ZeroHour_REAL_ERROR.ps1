$ErrorActionPreference = "Continue"

$ADB = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$OUT = "$env:USERPROFILE\Desktop\ZeroHour_REAL_ERROR.txt"
$CACHE = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN\build\android-vulkan\CMakeCache.txt"

"" | Out-File $OUT -Encoding utf8

function W([string]$s) {
    Write-Host $s
    $s | Out-File $OUT -Append -Encoding utf8
}

W "ZERO HOUR - REAL ERROR CAPTURE"
W "========================================"
W ""

if (!(Test-Path $ADB)) {
    W "ERROR: adb.exe not found."
    exit 1
}

& $ADB start-server | Out-Null

W "===== DEVICE ====="
& $ADB devices 2>&1 | ForEach-Object { W $_.ToString() }
W ""

W "===== APP EXIT STATE ====="
& $ADB shell dumpsys activity exit-info me.generalsx.zh 2>&1 |
    Select-Object -First 160 |
    ForEach-Object { W $_.ToString() }
W ""

W "===== ENGINE STDERR CURRENT ====="
$current = & $ADB shell run-as me.generalsx.zh cat files/generals-stderr.log 2>&1
if ($LASTEXITCODE -eq 0) {
    $current | ForEach-Object { W $_.ToString() }
} else {
    W "Could not read files/generals-stderr.log"
    $current | ForEach-Object { W $_.ToString() }
}
W ""

W "===== ENGINE STDERR PREVIOUS ====="
$prev = & $ADB shell run-as me.generalsx.zh cat files/generals-stderr-prev.log 2>&1
if ($LASTEXITCODE -eq 0) {
    $prev | ForEach-Object { W $_.ToString() }
} else {
    W "Could not read files/generals-stderr-prev.log"
    $prev | ForEach-Object { W $_.ToString() }
}
W ""

W "===== CMAKE MEMORY CONFIG ====="
if (Test-Path $CACHE) {
    Get-Content $CACHE |
        Select-String -Pattern "RTS_GAMEMEMORY_ENABLE|RTS_BUILD_OPTION_FFMPEG|SAGE_USE_OPENAL|SAGE_USE_SDL3|SAGE_DXVK_USE_LOCAL_FORK|CMAKE_BUILD_TYPE" |
        ForEach-Object { W $_.Line }
} else {
    W "CMakeCache.txt not found."
}
W ""

W "===== RECENT GENERALS LOGCAT ====="
& $ADB logcat -d -v time 2>&1 |
    Select-String -Pattern "GeneralsX|me.generalsx.zh|SDL_main|GameMain|GameData|CWD|ERROR|FATAL|Scudo|SIGABRT|SIGSEGV|DXVK|Vulkan|Mali|OpenAL|exit" |
    Select-Object -Last 500 |
    ForEach-Object { W $_.Line }

W ""
W "========================================"
W "DONE"
W "SEND THIS ONE FILE TO CHATGPT:"
W $OUT

Write-Host ""
Write-Host "Done. Send me only:"
Write-Host $OUT
