#!/usr/bin/env python3
"""Instrument the *actual Zero Hour* GameEngine::init path on Android.

V7 accidentally targeted Generals/..., while the Android Gradle configuration
builds target z_generals from GeneralsMD/... when RTS_BUILD_ZEROHOUR is enabled.
V8 patches GeneralsMD/Code/GameEngine/Source/Common/GameEngine.cpp only.

No gameplay behavior is changed. Existing GX_LOG (Android Logcat tag GeneralsX)
is used so every diagnostic marker is visible even when the process exits early.
"""
from __future__ import annotations

from pathlib import Path
import shutil
import sys

ROOT = Path(r"C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN")
CPP = ROOT / "GeneralsMD" / "Code" / "GameEngine" / "Source" / "Common" / "GameEngine.cpp"
MARKER = "ZEROHOUR_ANDROID_INIT_GATE_V8"
LOG_PREFIX = "ZH_INIT_GATE_V8"

# Sequential operations after the last already-proven runtime marker:
#   GE::init: ThingFactory done
# Every original statement is preserved exactly and merely surrounded with
# BEGIN/OK log markers.
GATES = [
    ("UpgradeCenter", "initSubsystem(TheUpgradeCenter,"),
    ("GameClient", "initSubsystem(TheGameClient,"),
    ("AI", "initSubsystem(TheAI,"),
    ("GameLogic", "initSubsystem(TheGameLogic,"),
    ("TeamFactory", "initSubsystem(TheTeamFactory,"),
    ("CrateSystem", "initSubsystem(TheCrateSystem,"),
    ("PlayerList", "initSubsystem(ThePlayerList,"),
    ("Recorder", "initSubsystem(TheRecorder,"),
    ("Radar", "initSubsystem(TheRadar,"),
    ("VictoryConditions", "initSubsystem(TheVictoryConditions,"),
    ("MetaMap", "initSubsystem(TheMetaMap,"),
    ("MetaMapGenerate", "TheMetaMap->generateMetaMap();"),
    ("MetaMapVerify", "TheMetaMap->verifyMetaMap();"),
    ("ActionManager", "initSubsystem(TheActionManager,"),
    ("GameStateMap", "initSubsystem(TheGameStateMap,"),
    ("GameState", "initSubsystem(TheGameState,"),
    ("GameResultsQueue", "initSubsystem(TheGameResultsQueue,"),
    ("PostProcessLoadAll", "TheSubsystemList->postProcessLoadAll();"),
]


def fail(msg: str) -> None:
    print(f"FAILED: {msg}", file=sys.stderr)
    raise SystemExit(1)


def unique_index(lines: list[str], needle: str, label: str, start: int = 0, end: int | None = None) -> int:
    stop = len(lines) if end is None else min(end, len(lines))
    hits = [i for i in range(start, stop) if needle in lines[i]]
    if len(hits) != 1:
        fail(f"{label}: expected exactly one anchor containing {needle!r}, found {len(hits)}")
    return hits[0]


def first_index(lines: list[str], needle: str, label: str, start: int = 0, end: int | None = None) -> int:
    stop = len(lines) if end is None else min(end, len(lines))
    for i in range(start, stop):
        if needle in lines[i]:
            return i
    fail(f"{label}: anchor containing {needle!r} not found")
    raise AssertionError("unreachable")


def find_init_bounds(lines: list[str]) -> tuple[int, int]:
    start = unique_index(lines, "void GameEngine::init()", "GameEngine::init declaration")
    # GameEngine::execute() follows init() in this source. Use it to prevent any
    # diagnostic lookup from drifting into later methods.
    end = first_index(lines, "void GameEngine::execute()", "GameEngine::execute declaration", start + 1)
    return start, end


def resolve_init_catches(lines: list[str]) -> tuple[int, int, int]:
    start, end = find_init_bounds(lines)
    ini_idx = first_index(lines, "catch (INIException e)", "init INIException catch", start, end)
    error_idx = unique_index(lines, "catch (ErrorCode ec)", "init ErrorCode catch", start, ini_idx)
    generic_idx = first_index(lines, "catch (...)" , "init generic catch", ini_idx + 1, end)
    return error_idx, ini_idx, generic_idx


def insert_after_open_brace(lines: list[str], catch_index: int, statement: str, label: str) -> None:
    for i in range(catch_index, min(catch_index + 5, len(lines))):
        if "{" in lines[i]:
            indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())] + "\t"
            lines.insert(i + 1, indent + statement + "\n")
            return
    fail(f"{label}: opening brace not found")


def main() -> int:
    if not CPP.is_file():
        fail(f"Zero Hour GameEngine.cpp not found: {CPP}")

    text = CPP.read_text(encoding="utf-8-sig")

    # Prove this is the actual Android Zero Hour translation unit before touching it.
    required_baseline = [
        '#define GX_LOG(...) __android_log_print(ANDROID_LOG_INFO, "GeneralsX", __VA_ARGS__)',
        'GX_LOG("GE::init: ThingFactory done")',
        "initSubsystem(TheUpgradeCenter,",
        "void GameEngine::init()",
    ]
    for token in required_baseline:
        if token not in text:
            fail(f"wrong or unexpected Zero Hour source; missing baseline token: {token}")

    if MARKER in text:
        print("V8 instrumentation already present in GeneralsMD source; left unchanged.")
        return 0

    lines = text.splitlines(keepends=True)
    init_start, init_end = find_init_bounds(lines)

    # Validate all anchors are unique inside GameEngine::init BEFORE mutation.
    for name, needle in GATES:
        unique_index(lines, needle, name, init_start, init_end)
    resolve_init_catches(lines)

    thing_idx = unique_index(lines, 'GX_LOG("GE::init: ThingFactory done")', "ThingFactory proven marker", init_start, init_end)
    first_gate_idx = unique_index(lines, "initSubsystem(TheUpgradeCenter,", "UpgradeCenter", init_start, init_end)
    if thing_idx >= first_gate_idx:
        fail("unexpected source order: ThingFactory marker is not before UpgradeCenter")

    backup = CPP.with_suffix(CPP.suffix + ".before_init_gate_v8.bak")
    if not backup.exists():
        shutil.copy2(CPP, backup)
        print(f"Backup: {backup}")

    # Put a persistent source marker adjacent to the already-existing GX_LOG macro.
    gx_define = unique_index(lines, '#define GX_LOG(...) __android_log_print', "GX_LOG Android define")
    lines.insert(gx_define + 1, f'// {MARKER}\n')

    # Re-resolve init bounds/anchors after marker insertion, then instrument bottom-up.
    init_start, init_end = find_init_bounds(lines)
    resolved: list[tuple[str, int]] = []
    for name, needle in GATES:
        resolved.append((name, unique_index(lines, needle, name, init_start, init_end)))

    for name, idx in sorted(resolved, key=lambda item: item[1], reverse=True):
        indent = lines[idx][: len(lines[idx]) - len(lines[idx].lstrip())]
        lines.insert(idx + 1, indent + f'GX_LOG("{LOG_PREFIX} OK {name}");\n')
        lines.insert(idx, indent + f'GX_LOG("{LOG_PREFIX} BEGIN {name}");\n')

    error_idx, ini_idx, generic_idx = resolve_init_catches(lines)

    # Bottom-up catch instrumentation keeps earlier indices valid.
    insert_after_open_brace(
        lines,
        generic_idx,
        f'GX_LOG("{LOG_PREFIX} CATCH unknown exception during GameEngine::init");',
        "generic catch",
    )
    insert_after_open_brace(
        lines,
        ini_idx,
        f'GX_LOG("{LOG_PREFIX} CATCH INIException message=%s", e.mFailureMessage ? e.mFailureMessage : "(null)");',
        "INIException catch",
    )
    insert_after_open_brace(
        lines,
        error_idx,
        f'GX_LOG("{LOG_PREFIX} CATCH ErrorCode=%d", static_cast<int>(ec));',
        "ErrorCode catch",
    )

    out = "".join(lines)
    required_after = [
        MARKER,
        f'GX_LOG("{LOG_PREFIX} BEGIN UpgradeCenter")',
        f'GX_LOG("{LOG_PREFIX} OK PostProcessLoadAll")',
        f'GX_LOG("{LOG_PREFIX} CATCH ErrorCode=%d"',
        f'GX_LOG("{LOG_PREFIX} CATCH INIException message=%s"',
        f'GX_LOG("{LOG_PREFIX} CATCH unknown exception during GameEngine::init")',
    ]
    for token in required_after:
        if token not in out:
            fail(f"post-patch verification missing token: {token}")

    CPP.write_text(out, encoding="utf-8", newline="")
    print("V8 Android Zero Hour init-gate instrumentation applied to GeneralsMD source.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
