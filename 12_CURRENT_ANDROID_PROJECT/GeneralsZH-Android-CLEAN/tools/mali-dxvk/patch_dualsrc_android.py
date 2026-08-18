import os
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])

candidates = []
for base in [src / "src"]:
    for p in base.rglob("*"):
        if not p.is_file() or p.suffix.lower() not in {".cpp",".h",".hpp",".c",".cc"}:
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = p.read_text(encoding="utf-8", errors="ignore")

        lines = text.splitlines()
        for i, line in enumerate(lines):
            if "dualSrcBlend" in line:
                lo = max(0, i - 10)
                hi = min(len(lines), i + 11)
                ctx = "\n".join(f"{j+1}: {lines[j]}" for j in range(lo, hi))
                candidates.append((p, i, line, ctx))

print(f"DUALSRC_OCCURRENCES={len(candidates)}")
for p, i, line, ctx in candidates:
    print(f"\n--- {p} : {i+1} ---")
    print(ctx)

# Only patch explicit assignments that make dualSrcBlend mandatory/enabled.
# For a D3D8->D3D9 Android build, setting this feature request to false
# is safe: unsupported hardware then remains false and no unsupported
# Vulkan feature is requested.
patterns = [
    re.compile(r'(\.dualSrcBlend\s*=\s*)VK_TRUE(\s*;)'),
    re.compile(r'(\.dualSrcBlend\s*=\s*)true(\s*;)'),
]

patched = []
for p, _, _, _ in candidates:
    try:
        text = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue

    original = text
    n_total = 0

    for pat in patterns:
        def repl(m):
            nonlocal_counter[0] += 1
            rhs = "VK_FALSE" if "VK_TRUE" in m.group(0) else "false"
            return m.group(1) + rhs + m.group(2) + " // ZEROHOUR_ANDROID_D3D8_MALI_DUALSRC_OPTIONAL"

        nonlocal_counter = [0]
        text = pat.sub(repl, text)
        n_total += nonlocal_counter[0]

    if text != original:
        backup = Path(str(p) + ".before_zh_dualsrc.bak")
        if not backup.exists():
            backup.write_text(original, encoding="utf-8")
        p.write_text(text, encoding="utf-8")
        patched.append((p, n_total))

print(f"\nPATCHED_FILES={len(patched)}")
print(f"PATCHED_ASSIGNMENTS={sum(n for _,n in patched)}")
for p,n in patched:
    print(f"PATCHED {n}: {p}")

if not patched:
    sys.exit(23)