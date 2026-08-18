# GeneralsX @feature android-port 06/07/2026
# Proguard is effectively a no-op for this app: the Java side is the SDLActivity
# stub (kept verbatim to match what nativeRunMain dlsyms), and the entire game
# is the libmain.so native engine. Keep everything.
-dontobfuscate
-keep class org.libsdl.app.** { *; }
-keep class me.generalsx.zh.** { *; }
