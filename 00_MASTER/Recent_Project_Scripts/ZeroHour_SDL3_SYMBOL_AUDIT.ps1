$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# ZERO HOUR - SDL3 SYMBOL AUDIT
#
# NO BUILD
# NO SOURCE EDIT
# NO APK INSTALL
# NO GAMEDATA COPY
#
# Finds out whether DXVK 2.7.1 is failing because its SDL3
# runtime function table expects symbols that the packaged
# libSDL3.so does not export. It also captures the exact source
# block that prints "Failed to load SDL3 DLL", so the next patch
# can target the real code instead of guessing.
#
# ONE OUTPUT:
# C:\Users\DELL\Desktop\ZeroHour_SDL3_SYMBOL_AUDIT.txt
# ============================================================

$ROOT = "C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN"
$WORK = "$ROOT\tools\mali-dxvk"
$DXVKSRC = "$WORK\actual-dxvk-source"

$SDK = "$env:LOCALAPPDATA\Android\Sdk"
$NDK = "$SDK\ndk\27.1.12297006"

$NM = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-nm.exe"
$READELF = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe"
$STRINGS = "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strings.exe"

$JNI = "$ROOT\android\app\src\main\jniLibs\arm64-v8a"
$SDL3 = "$JNI\libSDL3.so"
$D3D8 = "$JNI\libdxvk_d3d8.so"

$WSI = "$DXVKSRC\src\wsi\sdl3\wsi_platform_sdl3.cpp"
$FUNCS = "$DXVKSRC\src\wsi\sdl3\wsi_platform_sdl3_funcs.h"

$OUT = "$env:USERPROFILE\Desktop\ZeroHour_SDL3_SYMBOL_AUDIT.txt"

"" | Out-File $OUT -Encoding utf8

function W([string]$s) {
    Write-Host $s
    $s | Out-File $OUT -Append -Encoding utf8
}

function S([string]$s) {
    W ""
    W "============================================================"
    W $s
    W "============================================================"
}

try {
    S "1/5 VERIFY"

    foreach ($p in @($ROOT,$DXVKSRC,$NM,$READELF,$STRINGS,$SDL3,$D3D8,$WSI,$FUNCS)) {
        if (!(Test-Path $p)) {
            throw "Missing required path: $p"
        }
        W "READY: $p"
    }


    S "2/5 SDL3 ELF IDENTITY"

    & $READELF --dynamic $SDL3 2>&1 |
        Select-String -Pattern "SONAME|NEEDED" |
        ForEach-Object { W $_.Line }

    W ""
    W "SDL3 strings mentioning version:"
    & $STRINGS $SDL3 2>&1 |
        Select-String -Pattern "SDL 3\.|SDL3|version" |
        Select-Object -First 80 |
        ForEach-Object { W $_.Line }


    S "3/5 DXVK EXPECTED SDL3 FUNCTION TABLE"

    $funcLines = Get-Content $FUNCS

    $expected = New-Object System.Collections.Generic.HashSet[string]

    foreach ($line in $funcLines) {
        if ($line -notmatch "SDL_PROC") { continue }

        # Accept different macro layouts by extracting every SDL_* token
        # from SDL_PROC lines, then discard common type-like tokens later.
        $ms = [regex]::Matches($line,'\bSDL_[A-Za-z0-9_]+\b')

        foreach ($m in $ms) {
            $name = $m.Value

            # Function names in this table are overwhelmingly SDL_*.
            # We will later keep only names that either exist as an export
            # or syntactically look like a function token.
            [void]$expected.Add($name)
        }
    }

    $expectedList = @($expected | Sort-Object)

    W "SDL_* TOKENS FOUND ON SDL_PROC LINES: $($expectedList.Count)"
    foreach ($e in $expectedList) {
        W "EXPECT_TOKEN: $e"
    }


    S "4/5 PACKAGED SDL3 EXPORTS + MISSING SYMBOLS"

    $nmOut = & $NM -D --defined-only $SDL3 2>&1

    $exports = New-Object System.Collections.Generic.HashSet[string]

    foreach ($line in @($nmOut)) {
        $s = $line.ToString().Trim()

        # llvm-nm output usually ends with the symbol name.
        if ($s -match '\b(SDL_[A-Za-z0-9_]+)$') {
            [void]$exports.Add($Matches[1])
        }
    }

    $exportList = @($exports | Sort-Object)

    W "SDL3 EXPORTED SDL_* SYMBOLS: $($exportList.Count)"

    # Refine expected tokens: keep tokens that are written as the function
    # argument of SDL_PROC where possible.
    $expectedFns = New-Object System.Collections.Generic.HashSet[string]

    foreach ($line in $funcLines) {
        if ($line -notmatch "SDL_PROC") { continue }

        # Common layouts:
        # SDL_PROC(ret, SDL_Foo, (...))
        # SDL_PROC(SDL_Foo, ret, (...))
        $tokens = @(
            [regex]::Matches($line,'\bSDL_[A-Za-z0-9_]+\b') |
            ForEach-Object { $_.Value }
        )

        foreach ($t in $tokens) {
            # Function names conventionally contain an action after SDL_.
            # Types commonly begin SDL_Window, SDL_DisplayID, SDL_PropertiesID,
            # SDL_bool, etc. If the token is exported, it is definitely a fn.
            if ($exports.Contains($t)) {
                [void]$expectedFns.Add($t)
            }
            elseif ($t -match '^SDL_(Get|Set|Create|Destroy|Vulkan|Show|Hide|Sync|Update|Pump|Wait|Poll|Add|Remove|Convert|Free|Claim|Release|Has|Is|Open|Close|Raise|Flash|Restore|Maximize|Minimize|Get|Set)') {
                [void]$expectedFns.Add($t)
            }
        }
    }

    $expectedFnList = @($expectedFns | Sort-Object)
    $missing = @()

    foreach ($e in $expectedFnList) {
        if (!$exports.Contains($e)) {
            $missing += $e
        }
    }

    W ""
    W "EXPECTED SDL3 FUNCTIONS AFTER FILTER: $($expectedFnList.Count)"
    W "MISSING FROM PACKAGED libSDL3.so: $($missing.Count)"

    if ($missing.Count -gt 0) {
        foreach ($m in $missing) {
            W "MISSING_SYMBOL: $m"
        }
    }
    else {
        W "MISSING_SYMBOL: NONE DETECTED"
    }

    W ""
    W "DXVK D3D8 unresolved/imported SDL names (if any):"
    & $NM -D --undefined-only $D3D8 2>&1 |
        Select-String -Pattern "SDL_" |
        ForEach-Object { W $_.Line }


    S "5/5 EXACT SDL3 LOADER SOURCE BLOCK"

    $all = Get-Content $WSI
    $hit = -1

    for ($i=0; $i -lt $all.Count; $i++) {
        if ($all[$i] -match "Failed to load SDL3 DLL") {
            $hit = $i
            break
        }
    }

    if ($hit -lt 0) {
        W "ERROR STRING NOT FOUND IN SOURCE."
    }
    else {
        $start = [Math]::Max(0,$hit-45)
        $end = [Math]::Min($all.Count-1,$hit+45)

        W "ERROR MESSAGE SOURCE LINE: $($hit+1)"
        W ""

        for ($i=$start; $i -le $end; $i++) {
            W ("{0,5}: {1}" -f ($i+1),$all[$i])
        }
    }

    W ""
    W "============================================================"
    W "AUDIT COMPLETE"
    W "SEND ME ONLY THIS FILE:"
    W $OUT
}
catch {
    W ""
    W "AUDIT EXCEPTION:"
    W ($_ | Out-String)
    W ""
    W "SEND ME ONLY THIS FILE:"
    W $OUT
}
