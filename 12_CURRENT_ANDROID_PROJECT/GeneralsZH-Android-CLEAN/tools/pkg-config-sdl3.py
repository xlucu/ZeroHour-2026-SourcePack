import sys

VERSION = "3.4.2"
INCLUDE = r"C:/Users/DELL/AndroidStudioProjects/GeneralsZH-Android-CLEAN/build/android-vulkan/_deps/sdl3-src/include"
LIBDIR  = r"C:/Users/DELL/AndroidStudioProjects/GeneralsZH-Android-CLEAN/build/android-vulkan/_deps/sdl3-build"

args = sys.argv[1:]

# Options pkg-config/Meson may add that do not change our result.
ignored_prefixes = (
    "--define-variable=",
)

filtered = []
for arg in args:
    if arg.startswith(ignored_prefixes):
        continue

    if arg in {
        "--print-errors",
        "--short-errors",
        "--silence-errors",
        "--errors-to-stdout",
        "--static",
        "--keep-system-cflags",
        "--keep-system-libs",
        "--define-prefix",
    }:
        continue

    filtered.append(arg)

args = filtered

packages = [
    a for a in args
    if not a.startswith("-")
]

# This shim intentionally exposes only SDL3.
if packages:
    for package in packages:
        if package.lower() != "sdl3":
            sys.exit(1)

if "--version" in args:
    print("2.5.1")
    sys.exit(0)

if "--exists" in args:
    sys.exit(0)

if "--modversion" in args:
    print(VERSION)
    sys.exit(0)

for arg in args:
    if arg.startswith("--atleast-version="):
        requested = arg.split("=", 1)[1]
        def nums(v):
            result=[]
            for p in v.split("."):
                try:
                    result.append(int(p))
                except:
                    result.append(0)
            return tuple(result)
        sys.exit(0 if nums(VERSION) >= nums(requested) else 1)

if "--print-variables" in args:
    print("prefix")
    print("libdir")
    print("includedir")
    sys.exit(0)

for arg in args:
    if arg.startswith("--variable="):
        variable = arg.split("=", 1)[1]

        if variable == "prefix":
            print(LIBDIR.rsplit("/", 1)[0])
        elif variable == "libdir":
            print(LIBDIR)
        elif variable == "includedir":
            print(INCLUDE)

        sys.exit(0)

out=[]

if "--cflags" in args or "--cflags-only-I" in args:
    out.append("-I" + INCLUDE)

if "--libs" in args:
    out.extend([
        "-L" + LIBDIR,
        "-lSDL3"
    ])

if "--libs-only-L" in args:
    out.append("-L" + LIBDIR)

if "--libs-only-l" in args:
    out.append("-lSDL3")

print(" ".join(out))
sys.exit(0)