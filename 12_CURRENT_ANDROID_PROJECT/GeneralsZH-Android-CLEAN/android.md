# Android Port: Status, Findings, and Fixes

**Last updated:** 2026-07-07 (main menu rendering achieved!)
**Target:** C&C Generals Zero Hour running natively on Android tablets (arm64-v8a)
**Approach:** Native port only (no Box64/emulation)

---

## 1. What We're Trying to Do

Get the full C&C Generals Zero Hour game engine (~500k LOC C++) running
**natively** on an Android tablet. This means:

- **DXVK (D3D8 → Vulkan)** translating the engine's DirectX 8 calls to Vulkan
  on Android's Adreno/Mali GPUs — the first-ever DXVK build for Android aarch64.
- **SDL3** as the windowing/input layer (replacing Win32 API).
- **OpenAL** for audio (replacing Miles Sound System).
- **FFmpeg stubbed** (vcpkg ffmpeg:arm64-android is broken — microsoft/vcpkg#33963).
- The engine cross-compiled with **Android NDK r27** + CMake, producing a
  `libmain.so` that SDL's `nativeRunMain` JNI entry point dlopens.
- **64-bit only** (arm64-v8a). No 32-bit path.

The goal is the game's **main menu rendering on the tablet screen**, proving
the full init pipeline works end-to-end: filesystem → BIG archives → INI
parsing → subsystem stores → DXVK device creation → rendering.

---

## 2. What's Been Achieved (The Milestones)

| Milestone | Status |
|-----------|--------|
| DXVK builds natively for Android aarch64 | ✅ Done (first-ever) |
| DXVK d3d8 clear test renders on Adreno 830 | ✅ Proven on real hardware |
| Full 500k LOC engine cross-compiles (20,811 symbols) | ✅ All subsystems compile |
| `libmain.so` produced for arm64-v8a | ✅ |
| Full APK packaged (libmain.so + DXVK + SDL3 + deps + fonts) | ✅ |
| 2GB GameData pushed to device external storage | ✅ |
| Engine finds and mounts BIG archives | ✅ |
| INI parsing works (GameData, Science, Terrain, etc.) | ✅ |
| Audio init passes (ZH music loaded with override fix) | ✅ |
| WeaponStore parses past FLESHY_SNIPER | ✅ (bugfix applied) |
| LocomotorStore loads ZH locomotors | ✅ (override fix applied) |
| Engine reaches DXVK device creation | ✅ (format + windowed fixes) |
| **Main menu renders on tablet** | **✅ Done! (07 Jul 2026)** |
| Menu button text visible (font rendering) | ✅ Done (APK asset extraction) |
| Touch input works (tap, drag, pinch) | ✅ Done (SAGE_MOBILE already implemented) |
| Audio playback | ⏳ Verify |
| Gameplay / full session | ⏳ Future |

---

## 3. Build & Deploy Workflow

### 3.1 Build the engine

```bash
# Configure (one-time)
cmake --preset android-game  # or the equivalent manual configure

# Build
cmake --build build/android-game --target z_generals
```

Key build flags:
- `-DRTS_GAMEMEMORY_ENABLE=OFF` — engine's custom DMA conflicts with libc++
  `c++_shared` (operator delete crash). Uses plain malloc/free.
- `-DRTS_BUILD_OPTION_FFMPEG=OFF` — FFmpeg stubbed for Android.
- `-DRTS_CRASHDUMP_ENABLE=OFF` — no minidump on Android.

### 3.2 Strip + package the APK

The APK is assembled from a staging directory at `build/android-spike/apk/`:

```bash
NDK="${HOME}/Library/Android/sdk/ndk/27.1.12297006"
STRIP="${NDK}/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"
STAGING="build/android-spike/apk"
BUILD_TOOLS="${HOME}/Library/Android/sdk/build-tools/36.1.0"
KEYSTORE="${HOME}/.android/debug.keystore"

# Strip debug symbols
"${STRIP}" --strip-debug -o "${STAGING}/lib/arm64-v8a/libmain.so" \
    build/android-game/GeneralsMD/Code/Main/libmain.so

# Replace libmain.so in the unsigned APK base
cp -f build/android-game/GeneralsZH-full-unsigned.apk \
      build/android-game/GeneralsZH-full-aligned.apk.tmp
( cd "${STAGING}" && zip build/android-game/GeneralsZH-full-aligned.apk.tmp \
    "lib/arm64-v8a/libmain.so" )

# Align + sign
"${BUILD_TOOLS}/zipalign" -f -p 4 \
    build/android-game/GeneralsZH-full-aligned.apk.tmp \
    build/android-game/GeneralsZH-full-aligned.apk
"${BUILD_TOOLS}/apksigner" sign \
    --ks "${KEYSTORE}" --ks-pass pass:android --key-pass pass:android \
    --out build/android-game/GeneralsZH-full.apk \
    build/android-game/GeneralsZH-full-aligned.apk
```

### 3.3 Install + run + capture logs

```bash
adb install -r build/android-game/GeneralsZH-full.apk
adb logcat -c
adb shell am start -n me.generalsx.spike/.SpikeActivity
sleep 20
adb logcat -d -s GeneralsX:V | tail -60
```

### 3.4 Game data on device

GameData lives in external storage:
```
/storage/emulated/0/Android/data/me.generalsx.spike/files/GameData/
  Data/
    INI.big
    INIZH.big
    Audio.big
    AudioZH.big
    ... (all .big archives)
  SagePatch.ini
```

The engine `chdir()`s into `<external>/GameData` on launch (see `SDL3Main.cpp`).

---

## 4. Bugs Found and Fixed

### 4.1 ✅ FLESHY_SNIPER DamageType compiled out for ZH

**Symptom:** Engine crashed during WeaponStore init:
```
Error parsing INI file 'Data\INI\Weapon.ini' (Line: 'Weapon CINE_USAPathfinderSniperRifle')
```

**Root cause:** The `DAMAGE_FLESHY_SNIPER` enum value and its name in
`DamageTypeFlags::s_bitNameList[]` were gated behind `#if RTS_GENERALS` only:

```cpp
// Damage.h — BEFORE (broken):
#if RTS_GENERALS
    DAMAGE_FLESHY_SNIPER = 31,
#endif

// Damage.cpp — BEFORE (broken):
#if RTS_GENERALS
    "FLESHY_SNIPER",
#endif
```

The ZH build (`RTS_ZEROHOUR=1`, `RTS_GENERALS` undefined) compiled out
`FLESHY_SNIPER` from the enum names list. But the ZH engine loads the
**base Generals** `INI.big`, whose `Weapon.ini` references `DamageType =
FLESHY_SNIPER` (e.g. `CINE_USAPathfinderSniperRifle`). The INI parser's
`scanIndexList("FLESHY_SNIPER", s_bitNameList)` found no match → threw
`INI_INVALID_DATA` → crash.

**Fix:** Include `FLESHY_SNIPER` for ZH too, since ZH loads base data:

```cpp
// Damage.h — AFTER:
DAMAGE_FLESHY_SNIPER = 31;  // no #if guard

// Damage.cpp — AFTER:
"FLESHY_SNIPER",  // no #if guard
```

The `/*= 32*/` commented-out values on subsequent entries confirm the
developers designed the enum so FLESHY_SNIPER occupies slot 31 regardless.

**Files changed:**
- `Core/GameEngine/Include/GameLogic/Damage.h`
- `Core/GameEngine/Source/GameLogic/System/Damage.cpp`

---

### 4.2 ✅ BIG archive file override (base vs ZH)

**Symptom:** LocomotorStore only parsed 40 locomotors from the base
Generals `Locomotor.ini`, missing all ZH-specific locomotors like
`SpectreGunshipTransitLocomotor`. When Object INI files referenced these
missing locomotors, the engine crashed:
```
Error parsing INI file 'Data\INI\Object\airforcegeneral.ini'
  (Line: 'Object AirF_AmericaJetSpectreGunship1')
```

**Root cause:** On a Complete Edition install, both base Generals
(`INI.big`) and Zero Hour (`INIZH.big`) archives are in the same `Data/`
directory. The BIG file loader `loadBigFilesFromDirectory()` used
`overwrite=FALSE` by default:

```cpp
// StdBIGFileSystem.cpp — BEFORE (broken):
static Bool tryLoadBigFiles(..., Bool overwrite = FALSE) {
    ...
    fileSystem->loadBigFilesFromDirectory(directory, "*.big", overwrite);
}
```

Files are loaded in alphabetical order (`INI.big` before `INIZH.big`).
With `overwrite=FALSE`, the FIRST-loaded version (base `INI.big`) is
inserted at the front of the `ArchivedFileLocationMap` multimap. The
`getArchiveFile()` function returns `range.get()->second` — the first
entry. So the base `Locomotor.ini` (40 entries, no ZH locomotors) always
won over the ZH version (182 entries).

**Fix:** Default `overwrite=TRUE` so later-loaded ZH archives override
base files:

```cpp
// StdBIGFileSystem.cpp — AFTER:
static Bool tryLoadBigFiles(..., Bool overwrite = TRUE) {
    ...
}
// Also: loadBigFilesFromDirectory("", "*.big", TRUE) for CWD fallback.
```

With `overwrite=TRUE`, INIZH.big's files are inserted at the **front** of
the multimap, so `getArchiveFile()` returns the ZH version.

**Side effect:** Audio music check now passes (`musicLoaded=1`) because
the ZH audio archives are correctly prioritized.

**Files changed:**
- `Core/GameEngineDevice/Source/StdDevice/Common/StdBIGFileSystem.cpp`

---

### 4.3 ✅ Multimap override precedence (resolving the 40/182 locomotor parsing issue)

**Symptom:** Only 40 of ~182 Zero Hour locomotors were being parsed. The parsing stopped after `BlimpLocomotor`. `SpectreGunshipTransitLocomotor` (defined in the Zero Hour `Locomotor.ini` in `INIZH.big`) was not loaded.

**Root cause:** The base Generals `Locomotor.ini` (inside `INI.big`) was still prioritized by the file system over the Zero Hour `Locomotor.ini` (inside `INIZH.big`). While `overwrite=TRUE` was passed, `ArchiveFileSystem::loadIntoDirectoryTree` used `std::multimap::insert(find(token), ...)` to insert the overriding file. In C++11 and later, `multimap::insert` with a hint does not guarantee that the new element is inserted at the beginning of the equal range (it is implementation-defined, and typically appends at the end of the equivalent key range). As a result, the base Generals version remained first in the `equal_range` and was returned by `getArchiveFile()`, while the Zero Hour version was placed second.

**Fix:** When `overwrite` is `TRUE`, we query all existing elements for that file `token` in the multimap, save them in a vector, erase them from the multimap, insert the new override (which becomes the first element), and then re-insert the erased elements. This guarantees that the new override element is at the beginning of the equal range (index 0) and takes precedence, while still preserving older instances at subsequent indices (which is essential for merging string tables like CSFs).

**Files changed:**
- `Core/GameEngine/Source/Common/System/ArchiveFileSystem.cpp`

---

### 4.4 ✅ LanguageRegistry crash on fresh install (no Options.ini)

**Symptom:** Engine crashed during early init in `LanguageRegistry::init()`
on a fresh Android install where no `Options.ini` exists.

**Root cause:** Without `Options.ini`, the engine has no language setting
configured. The language registry tries to look up a registry entry or
configuration file that doesn't exist and throws an exception.

**Fix:** Added a fallback to default English when registry entries or
configuration files are missing.

**Files changed:**
- `GeneralsMD/Code/GameEngine/Source/Common/GameEngine.cpp`

---

### 4.5 ✅ Global allocator / deallocator incompatibility (heap corruption)

**Symptom:** Random crashes in `operator delete` / `operator delete[]` —
the engine's custom memory allocator (`TheDynamicMemoryAllocator`) tried
to free memory that was allocated by the standard system allocator
(via `::malloc`), causing heap corruption.

**Root cause:** External libraries (OpenAL, libc++ containers) allocate
memory using the standard system allocator, but the engine intercepted
global `operator delete` and routed ALL deallocations through its custom
pool allocator. When these external allocations were freed through the
engine's custom path, the pool allocator corrupted its internal state.

**Fix:** Added a magic cookie field (`m_dmaMagicCookie = 0x47454d53`) in
`MemoryPoolSingleBlock::initBlock()`. Updated global `operator delete`
and `operator delete[]` to check for this cookie before routing to
`TheDynamicMemoryAllocator->freeBytes()`. If the cookie is not present,
the memory is freed via standard `::free()` instead.

**Files changed:**
- `Core/GameEngine/Include/Common/System/GameMemory.h` — added cookie field + getter
- `Core/GameEngine/Source/Common/System/GameMemory.cpp` — cookie init + delete routing

---

### 4.6 ✅ DXVK CreateDevice fails with D3DERR_NOTAVAILABLE (BackBufferFormat=UNKNOWN)

**Symptom:** `D3DInterface->CreateDevice()` failed with HRESULT `0x8876086A`
(`D3DERR_NOTAVAILABLE`). The engine logged `BackBufferFormat=0`
(`D3DFMT_UNKNOWN`) in the `_PresentParameters`.

**Root cause:** Two interacting issues:

1. **Windowed presentation mismatch**: DXVK on non-Windows platforms always
   needs `_PresentParameters.Windowed = TRUE` (there's no Win32 fullscreen
   concept). The existing Linux/macOS fix for this correctly set
   `Windowed = TRUE`, but the `#if` guard excluded Android/iOS:
   ```cpp
   // BEFORE — excluded Android:
   #if !defined(_WIN32) && !defined(__ANDROID__) && ...
   _PresentParameters.Windowed = TRUE;
   ```

2. **Format selection path mismatch**: The engine's format selection code
   branches on `if (IsWindowed)`. The engine's `IsWindowed` variable was
   `false` (game defaults to fullscreen), so it entered the fullscreen
   format-selection path which calls `Find_Color_And_Z_Mode()`. On Android,
   this function fails because there are no enumerated fullscreen display
   modes, leaving `BackBufferFormat = D3DFMT_UNKNOWN` (0).

   Meanwhile, `_PresentParameters.Windowed` was forced to `TRUE` for DXVK,
   so DXVK received `Windowed=1` with `BackBufferFormat=UNKNOWN` — an
   invalid combination that DXVK correctly rejects.

**Fix (3 changes in `dx8wrapper.cpp`):**

1. Simplified the windowed presentation guard to `#ifndef _WIN32` so ALL
   non-Windows platforms (including Android/iOS) force
   `_PresentParameters.Windowed = TRUE`.

2. Changed the format-selection branch to always use the windowed code path
   on non-Windows (`#ifndef _WIN32 { #else if (IsWindowed) { #endif`),
   since DXVK always operates in windowed presentation mode.

3. Added a fallback: if `GetAdapterDisplayMode()` returns `D3DFMT_UNKNOWN`
   on Android (no desktop mode), default to `D3DFMT_X8R8G8B8` (32-bit).

**Result:** `CreateDevice` succeeds with:
```
BackBufferFormat=21 (D3DFMT_A8R8G8B8)  Windowed=1
AutoDepthStencilFormat=75 (D3DFMT_D24S8)
```

**Files changed:**
- `Core/Libraries/Source/WWVegas/WW3D2/dx8wrapper.cpp`

---

### 4.7 ✅ Menu button text missing (font extraction from APK assets)

**Symptom:** The main menu rendered correctly (background scene, button
outlines) but button text was invisible/missing. No text appeared on any
UI element.

**Root cause:** The engine's FreeType font locator
(`FontCharsClass::Locate_Font_FontConfig` in `render2dsentence.cpp`)
probes `<CWD>/fonts/<name>.ttf` via `access()`. On Android, CWD is
`<storage>/GameData/`. The four font files (Liberation fonts renamed to
Windows names: `arial.ttf`, `arialbold.ttf`, `couriernew.ttf`,
`timesnewroman.ttf`) were bundled as **APK assets** in `assets/fonts/`.

**Android APK assets are invisible to `access()`/`fopen()`** — they're
not real filesystem paths. No code existed to extract them.

**Fix:** Added native font extraction in `SDL3Main.cpp` that runs on
first launch:
1. Creates `<storage>/GameData/fonts/` directory
2. Obtains `AAssetManager` via JNI (`SDL_GetAndroidJNIEnv` +
   `SDL_GetAndroidActivity` → `getAssets()` → `AAssetManager_fromJava`)
3. For each font file: `AAssetManager_open` → `AAsset_read` loop →
   writes to filesystem
4. Skips extraction if `fonts/arial.ttf` already exists (idempotent)

**Files changed:**
- `GeneralsMD/Code/Main/SDL3Main.cpp` — font extraction logic
- `GeneralsMD/Code/Main/CMakeLists.txt` — link `libandroid` for AAssetManager

---

### 4.8 Touch Input — Already Working (SAGE_MOBILE)

**Finding:** Touch input was already fully implemented via the `SAGE_MOBILE`
macro (defined when `__ANDROID__` is set). The implementation in
`SDL3GameEngine.cpp` includes:

- A `TouchState` gesture state machine: IDLE → PENDING → TAP/DRAG/LONGPRESS/PAN
- `handleTouchEvent()` processing `SDL_EVENT_FINGER_DOWN/MOTION/UP/CANCELED`
- `sendSyntheticMouse()` injecting synthetic `SDL_EVENT_MOUSE_*` events
  through the same `SDL3Mouse::addSDLEvent()` path real mice use
- Gestures: 1-finger tap → left click, 1-finger drag → drag-box,
  1-finger long-press → right click, 2-finger drag → camera pan,
  2-finger pinch → zoom wheel

**Verification:** Tapping the screen via `adb shell input tap` produces
`FINGER_DOWN` → `FINGER_UP` events that correctly flow through the
synthetic mouse pipeline. Tapping menu buttons triggers UI responses
(screen content changes).

**No code changes needed** — the existing implementation works correctly.

---

## 5. Bugs Found and Fixed (Earlier in the Port)

These were resolved in prior sessions and are documented for reference:

| Bug | Fix |
|-----|-----|
| DXVK `-msse` on aarch64 | Gate SSE flags behind x86 in meson.build |
| `VK_ENABLE_BETA_EXTENSIONS` | Add to DXVK NDK cross-file |
| DXVK SDL3 WSI soname (`libSDL3.so.0` → `libSDL3.so`) | Patch `wsi_platform_sdl3.cpp` |
| `pthread_cancel` missing in bionic | Stub C file + warning suppression |
| `sys/timeb.h` missing | Guard with `#if !defined(__ANDROID__)` |
| `std::from_chars` float missing in NDK libc++ | Disable `USE_STD_FROM_CHARS_PARSING` for Android |
| FFmpeg missing | `FFmpegAndroidStub.h` + `FFmpegFileStub.cpp` |
| DMA operator delete crash | `RTS_GAMEMEMORY_ENABLE=OFF` (now fixed properly — see 4.5) |
| `GlobalData::BuildUserDataPathFromRegistry` crash | Return `"./"` on Android |
| Audio music check forcing quit | Bypass `isMusicAlreadyLoaded()` check on Android |
| `glob()` requires API 28+ | Guard `FilterSoftwareVulkanICDs` with `#if !defined(__ANDROID__)` |

---

## 6. Key Diagnostic Technique: Logcat Instrumentation

The engine's INI parser has a generic `catch(...)` that wraps every parse
failure into a uniform "Error parsing INI file" message, hiding the real
exception. To debug, we added targeted `__android_log_print` diagnostics:

### 6.1 INI block/field failure logging (`INI.cpp`)

```cpp
#if defined(__ANDROID__)
catch (const std::exception& ex) {
    GX_INI_LOG("INI BLOCK FAILED: block='%s' excType='%s' what='%s'",
        token, typeid(ex).name(), ex.what());
    ...
} catch (...) {
    GX_INI_LOG("INI BLOCK FAILED (non-std): block='%s'", token);
    ...
}
#endif
```

This revealed that the exceptions are **non-std** (thrown as `int` enum
values like `INI_INVALID_DATA`), not `std::exception`.

### 6.2 scanIndexList unmatched token logging (`INI.cpp`)

```cpp
#if defined(__ANDROID__)
// In scanIndexList, when a token isn't found:
GX_INI_LOG("scanIndexList: token '%s' NOT FOUND in list:", token);
for (ConstCharPtrArray name = nameList; *name; name++, idx++) {
    GX_INI_LOG("  [%d] = '%s'", idx, *name);
}
#endif
```

This pinpointed `FLESHY_SNIPER` as the unmatched DamageType token.

### 6.3 Archive directory tree diagnostics (`ArchiveFile.cpp`)

Logged `addFile()` paths, `getFileListInDirectory()` traversal, and root
subdir counts to verify the BIG archive directory tree was built correctly.

**Key lesson:** logcat buffers are small (~256KB default). Verbose
per-entry logging (e.g. logging every BIG file entry) overflows the buffer
and hides the actual crash logs. Use `adb logcat -G 16M` to increase the
buffer, or filter diagnostics to specific files/conditions.

---

## 7. Current State and Next Steps

### 7.1 Where we are now (🎉 Main menu rendering + text + touch!)

The full engine init pipeline completes end-to-end and the **main menu
renders on the tablet screen** at native resolution (3392×2400) on an
Adreno 830 GPU:

```
FileSystem → BIG archives → GameData → Science → Multiplayer → Terrain →
Audio (musicLoaded=1) → GameText → FunctionLexicon → ModuleFactory →
RankInfo → PlayerTemplate → FXList → Weapon → ObjectCreationList →
Locomotor (182 parsed) → ThingFactory → ... → DXVK device creation →
Init complete → execute() main loop running
```

The 3D scene, tanks, explosions, soldiers, buildings, terrain, and the
C&C Generals Zero Hour logo all render correctly. **Menu button text is
visible** (fonts extracted from APK assets). **Touch input works** —
tapping menu buttons triggers UI navigation.

Process stats while running: ~2GB RSS, 31 threads, no crashes.

### 7.2 Remaining work

1. **Remove diagnostic instrumentation** once stable (LocoStore logs, INI
   field diagnostics, touch event logging).
2. **Performance profiling** — measure frame rate, identify bottlenecks.
3. **Audio playback** — verify OpenAL actually produces sound output.
4. **Commit the port progress**.

---

## 8. Architecture Notes

### 8.1 File system layering

The engine has a layered virtual file system:

```
FileSystem (orchestrator)
├── LocalFileSystem     — loose files on disk (std::filesystem)
└── ArchiveFileSystem   — files inside .big archives
    ├── ArchiveFile (INI.big)      — individual archive's directory tree
    ├── ArchiveFile (INIZH.big)
    ├── ArchiveFile (Audio.big)
    └── ... (27 archives total)
    └── m_rootDirectory (MERGED)   — union of all archives, used by doesFileExist/openFile
```

Two distinct directory tree types:
- `DetailedArchivedDirectoryInfo` — per-ArchiveFile trees (used by
  `getFileListInDirectory` for directory enumeration)
- `ArchivedDirectoryInfo` — the merged tree in ArchiveFileSystem (used by
  `doesFileExist`, `openFile`, `getArchiveFile`)

`loadIntoDirectoryTree()` enumerates each ArchiveFile via
`getFileListInDirectory("", "", "*", ...)` and merges into the
ArchiveFileSystem's `m_rootDirectory`.

### 8.2 File override priority

`ArchivedFileLocationMap` is a `std::multimap` allowing duplicate keys.
- `overwrite=FALSE` → new entries appended to END → first-loaded wins
- `overwrite=TRUE` → new entries inserted at FRONT → last-loaded wins

`getArchiveFile(filename, instance=0)` returns the FIRST match, so the
front entry determines which archive's version of a file is used.

### 8.3 INI parsing and exceptions

The INI parser throws raw `int` values (enum constants like
`INI_INVALID_DATA`, `INI_UNKNOWN_TOKEN`) — NOT `std::exception` subclasses.
This is why `catch(const std::exception&)` doesn't match and the generic
`catch(...)` fires. The `RELEASE_CRASH` mechanism then calls `_exit(1)`.

### 8.4 The NameKey system

`NAMEKEY("SomeName")` calls `TheNameKeyGenerator->nameToKey(name)` which
assigns sequential IDs at runtime. The key is deterministic within a
single process run — the same string always maps to the same key. Lookups
use the same mechanism, so they're consistent as long as both the
definition and reference use the exact same string.

---

## 9. Key Files Modified for Android

| File | Purpose |
|------|---------|
| `Core/GameEngine/Include/GameLogic/Damage.h` | FLESHY_SNIPER fix |
| `Core/GameEngine/Source/GameLogic/System/Damage.cpp` | FLESHY_SNIPER name list fix |
| `Core/GameEngineDevice/Source/StdDevice/Common/StdBIGFileSystem.cpp` | BIG override fix |
| `Core/GameEngine/Source/Common/INI/INI.cpp` | from_chars guard, INI diagnostics |
| `GeneralsMD/Code/GameEngine/Source/Common/GameEngine.cpp` | Android GX_LOG, audio bypass, lang fallback |
| `GeneralsMD/Code/GameEngine/Source/Common/GameMain.cpp` | Init diagnostics |
| `GeneralsMD/Code/GameEngine/Source/Common/GlobalData.cpp` | BuildUserDataPath Android fix |
| `GeneralsMD/Code/GameEngine/Source/GameLogic/Object/Locomotor.cpp` | Locomotor diagnostics |
| `GeneralsMD/Code/GameEngine/Source/GameLogic/Object/Update/AIUpdate.cpp` | parseLocomotorSet diagnostics |
| `Core/GameEngineDevice/Source/OpenALAudioDevice/OpenALAudioManager.cpp` | FFmpeg guard |
| `Core/GameEngineDevice/Include/VideoDevice/FFmpeg/FFmpegAndroidStub.h` | FFmpeg stub (created) |
| `Core/GameEngineDevice/Source/VideoDevice/FFmpeg/FFmpegFileStub.cpp` | FFmpeg stub (created) |
| `Core/GameEngineDevice/CMakeLists.txt` | Android FFmpeg stub, DXVK includes |
| `Core/GameEngine/Include/Common/System/GameMemory.h` | DMA magic cookie field |
| `Core/GameEngine/Source/Common/System/GameMemory.cpp` | Cookie init + safe delete routing |
| `Core/Libraries/Source/WWVegas/WW3D2/dx8wrapper.cpp` | DXVK format fix, windowed presentation, logcat |
| `GeneralsMD/Code/CompatLib/CMakeLists.txt` | Android shared lib, GLM, DXVK |
| `GeneralsMD/Code/Main/CMakeLists.txt` | Android libmain.so, -llog |
| `cmake/dx8.cmake` | Android DXVK build via Meson |
| `cmake/freetype.cmake` | FreeType FetchContent for Android |
| `cmake/android-deps.cmake` | GLM FetchContent for Android |
| `cmake/gamespy.cmake` | pthread_cancel stub |
| `cmake/sdl3.cmake` | SDL_image PNG config |
| `Patches/dxvk-android.patch` | SSE gating, WSI soname, high-DPI fix |
| `GeneralsMD/Code/Main/SDL3Main.cpp` | Android entry point, VFS, env vars, font extraction |
| `GeneralsMD/Code/Main/CMakeLists.txt` | Android libmain.so, -llog, -landroid |
| `GeneralsMD/Code/GameEngineDevice/Source/SDL3GameEngine.cpp` | Touch event dispatch (SAGE_MOBILE), diagnostics |
