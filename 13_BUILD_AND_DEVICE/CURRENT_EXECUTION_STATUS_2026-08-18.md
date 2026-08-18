# Zero Hour Android 2026 — Current Execution Status

Date: 2026-08-18
Branch: `agent/mali-dualsrc-v3`

## LAST PROVEN SUCCESS

The existing Android runtime has already progressed through the real engine startup far enough to:

- load the real Zero Hour game data and INI/CSF content;
- create the SDL window;
- load `libdxvk_d3d8.so`;
- resolve/call `Direct3DCreate8`;
- initialize DXVK 2.7.1;
- use the proven Android SDL3 direct-`dlopen` path (`ZH_ANDROID_SDL3_DLOPEN_OK`);
- initialize the Vulkan loader and enumerate the Mali-G615 MC6 GPU;
- preserve repaired APK native-library packaging (ELF instead of ZIP-magic payloads).

## FIRST PROVEN BLOCKER

Current runtime gate from the existing handoff/log history:

```text
Skipping: Device does not support required feature 'dualSrcBlend'
DXVK: No adapters found.
```

The corresponding DXVK source requirement is in:

```text
C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN\tools\mali-dxvk\actual-dxvk-source\src\dxvk\dxvk_device_info.cpp
```

with the exact expected line:

```cpp
ENABLE_FEATURE(core.features, dualSrcBlend, true),
```

## IMPLEMENTED NEXT GATE

`ZeroHour_MALI_DUALSRC_FIX_V3.ps1` was added under `13_BUILD_AND_DEVICE/`.

The script is deliberately narrow and fail-closed. It:

1. Verifies the current project/DXVK paths.
2. Requires the already-proven SDL3 Android direct-loader patch to still exist.
3. Changes only the Android adapter-enumeration requirement for `dualSrcBlend` from required to optional while leaving non-Android behavior unchanged.
4. Rebuilds the existing DXVK tree incrementally; it does not clone a new tree.
5. Verifies the rebuilt D3D8/D3D9 outputs are ELF files.
6. Stages only the rebuilt DXVK D3D8/D3D9 libraries.
7. Requires Gradle's `SAGE_SKIP_NATIVE_BUILD` package-only guard and `useLegacyPackaging false`.
8. Packages the APK using `-PSAGE_SKIP_NATIVE_BUILD=true`, so the native engine (`libmain.so`) is not intentionally rebuilt.
9. Verifies packaged D3D8/D3D9/SDL3 libraries are ELF and stored uncompressed.
10. Requires exactly one authorized Android device.
11. Installs with `adb install -r -d` without copying or modifying GameData.
12. Launches `me.generalsx.zh/.GameActivity`.
13. Captures one runtime log at `C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt`.
14. Prints the next recognized Vulkan/DXVK/runtime blocker instead of claiming success.

## EXACT REQUIRED ACTION

Run the V3 script on the Windows development machine with the target phone connected and authorized. The cloud execution environment cannot access `C:\Users\DELL\...` or the USB-connected phone, so this hardware/runtime gate cannot be proven remotely.

After that run, the next engineering action is determined only by the first real error in `C:\Users\DELL\Desktop\ZeroHour_MALI_LOG.txt`.

Do not re-clone DXVK, do not recopy the original GameData, and do not move on to touch/Direct Control until the renderer/runtime baseline is stable.
