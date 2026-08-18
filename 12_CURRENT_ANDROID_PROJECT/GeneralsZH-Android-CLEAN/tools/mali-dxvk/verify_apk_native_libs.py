import sys, zipfile, struct

apk = sys.argv[1]
targets = {
    "lib/arm64-v8a/libdxvk_d3d8.so",
    "lib/arm64-v8a/libdxvk_d3d9.so",
    "lib/arm64-v8a/libSDL3.so",
}

ok = True

with zipfile.ZipFile(apk, "r") as z:
    names = set(z.namelist())

    for name in sorted(targets):
        if name not in names:
            print(f"APK_MISSING {name}")
            ok = False
            continue

        info = z.getinfo(name)
        with z.open(name, "r") as f:
            magic = f.read(8)

        method = "STORED" if info.compress_type == zipfile.ZIP_STORED else f"COMPRESSED({info.compress_type})"
        print(f"APK_ENTRY {name} method={method} size={info.file_size} csize={info.compress_size} magic={magic.hex().upper()}")

        if not magic.startswith(b"\x7fELF"):
            print(f"APK_BAD_ELF {name}")
            ok = False

        if info.compress_type != zipfile.ZIP_STORED:
            print(f"APK_BAD_COMPRESSION {name}")
            ok = False

sys.exit(0 if ok else 17)