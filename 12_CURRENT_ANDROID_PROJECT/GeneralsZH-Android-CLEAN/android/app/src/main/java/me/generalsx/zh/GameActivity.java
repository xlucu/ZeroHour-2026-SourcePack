// GeneralsX @feature android-port 06/07/2026
//
// GameActivity — the Android entry point. Mirrors what iOS gets for free from
// SDL's UIApplicationMain bootstrap: load the native library, hand control to
// SDL_main(). SDL3 ships SDLActivity.java (via the FetchContent'd SDL3 source
// under android-project/app/src/main/java/org/libsdl/app/); the packaging script
// copies it in. We subclass it only to pin the package name + set library hints
// before SDL's nativeInit runs.
//
// On launch: SDLActivity.onCreate -> System.loadLibrary("SDL3") ->
// nativeRunMain("main", "SDL_main", argv) -> dlopen("libmain.so") -> SDL_main().
//
// The native SDL_main lives in GeneralsMD/Code/Main/SDL3Main.cpp (renamed by
// SDL3/SDL_main.h on Android). Everything else — Vulkan surface creation, touch
// routing, lifecycle — is handled by the engine + SDL3, identical to iOS.

package me.generalsx.zh;

import org.libsdl.app.SDLActivity;

public class GameActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        // Order matters: the engine (libmain.so) dlopens libdxvk_d3d8.so, which
        // pulls libvulkan.so. SDL3 + SDL3_image are the windowing/asset layer.
        // Preloading them here makes them resolvable inside the app's linker
        // namespace before the engine's dlopen() runs (Android API 24+ namespace
        // isolation requires a lib to be registered via loadLibrary before a
        // bare-name dlopen can find it).
        return new String[]{
            "SDL3",
            "SDL3_image",
            "openal",
            "dxvk_d3d9",
            "dxvk_d3d8",
            "main"
        };
    }

    @Override
    protected String getMainFunction() {
        // The symbol nativeRunMain dlsyms inside libmain.so.
        return "SDL_main";
    }
}
