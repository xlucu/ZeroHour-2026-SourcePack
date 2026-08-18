# ZeroHour_MALI_DUALSRC_FIX_V4.ps1
# Bootstrap fix for the proven V3 blocker: ninja.exe exists with Android CMake
# but was not present in PATH. This wrapper locates Ninja safely, adds only its
# directory to PATH for this process, then runs the guarded V3 flow unchanged.
# Windows PowerShell 5.1 compatible.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Sdk = 'C:\Users\DELL\AppData\Local\Android\Sdk'
$PreferredNinja = Join-Path $Sdk 'cmake\3.31.6\bin\ninja.exe'
$NinjaPath = $null

Write-Host ''
Write-Host '=== Locate Android Ninja ===' -ForegroundColor Cyan

$cmd = Get-Command ninja.exe -ErrorAction SilentlyContinue
if (-not $cmd) { $cmd = Get-Command ninja -ErrorAction SilentlyContinue }
if ($cmd) {
    $NinjaPath = $cmd.Source
}

if (-not $NinjaPath -and (Test-Path -LiteralPath $PreferredNinja)) {
    $NinjaPath = $PreferredNinja
}

if (-not $NinjaPath) {
    $cmakeRoot = Join-Path $Sdk 'cmake'
    if (Test-Path -LiteralPath $cmakeRoot) {
        $candidate = Get-ChildItem -LiteralPath $cmakeRoot -Recurse -Filter 'ninja.exe' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\bin\\ninja\.exe$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($candidate) { $NinjaPath = $candidate.FullName }
    }
}

if (-not $NinjaPath -or -not (Test-Path -LiteralPath $NinjaPath)) {
    throw "ninja.exe was not found under Android SDK CMake: $Sdk\cmake"
}

$NinjaDir = Split-Path -Parent $NinjaPath
$env:Path = $NinjaDir + ';' + $env:Path
Write-Host ('Ninja found: ' + $NinjaPath) -ForegroundColor Green

# Prove the selected executable actually runs before entering the V3 flow.
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $NinjaPath --version
$ninjaCode = $LASTEXITCODE
$ErrorActionPreference = $old
if ($ninjaCode -ne 0) {
    throw "ninja.exe exists but failed to execute. ExitCode=$ninjaCode Path=$NinjaPath"
}

Write-Host ''
Write-Host '=== Continue guarded Mali dualSrcBlend flow ===' -ForegroundColor Cyan
$V3Url = 'https://raw.githubusercontent.com/xlucu/ZeroHour-2026-SourcePack/agent/mali-dualsrc-v3/13_BUILD_AND_DEVICE/ZeroHour_MALI_DUALSRC_FIX_V3.ps1'
$V3File = Join-Path $env:TEMP 'ZeroHour_MALI_DUALSRC_FIX_V3.ps1'
Invoke-WebRequest -UseBasicParsing $V3Url -OutFile $V3File

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $V3File
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "V3 execution failed with exit code $exitCode"
}

Write-Host ''
Write-Host 'V4 bootstrap completed; V3 runtime log remains the authority.' -ForegroundColor Green
