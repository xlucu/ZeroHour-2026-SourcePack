#!/usr/bin/env python3
"""Android-only diagnostic instrumentation for the post-ThingFactory init exit.

This patch changes no gameplay state. It writes sequential GameEngine::init gate
markers to ZeroHour_InitGate.txt in the process current working directory so the
PowerShell runner can retrieve it with `adb shell run-as` even if the process
exits before renderer initialization.
"""
from __future__ import annotations

from pathlib import Path
import shutil
import sys

ROOT = Path(r"C:\Users\DELL\AndroidStudioProjects\GeneralsZH-Android-CLEAN")
CPP = ROOT / "Generals" / "Code" / "GameEngine" / "Source" / "Common" / "GameEngine.cpp"
MARKER = "ZEROHOUR_ANDROID_INIT_GATE_V7"

# Sequential anchors after the last proven runtime marker (ThingFactory done).
# These are diagnostics only; each original statement remains unchanged and is
# merely surrounded by BEGIN/OK file-log calls.
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

HELPER = r'''
#include <cstdio>
// ZEROHOUR_ANDROID_INIT_GATE_V7
static void ZeroHour_Android_InitGate_Log(const char *message)
{
#if defined(__ANDROID__)
    FILE *f = fopen("ZeroHour_InitGate.txt", "a");
    if (f != nullptr)
    {
        fprintf(f, "%s\n", message != nullptr ? message : "(null)");
        fflush(f);
        fclose(f);
    }
#else
    (void)message;
#endif
}

static void ZeroHour_Android_InitGate_LogCode(const char *prefix, int code)
{
#if defined(__ANDROID__)
    FILE *f = fopen("ZeroHour_InitGate.txt", "a");
    if (f != nullptr)
    {
        fprintf(f, "%s %d\n", prefix != nullptr ? prefix : "CODE", code);
        fflush(f);
        fclose(f);
    }
#else
    (void)prefix;
    (void)code;
#endif
}
'''.lstrip("\n")


def fail(msg: str) -> None:
    print(f"FAILED: {msg}", file=sys.stderr)
    raise SystemExit(1)


def unique_index(lines: list[str], needle: str, label: str, start: int = 0) -> int:
    hits = [i for i in range(start, len(lines)) if needle in lines[i]]
    if len(hits) != 1:
        fail(f"{label}: expected exactly one anchor containing {needle!r}, found {len(hits)}")
    return hits[0]


def first_index(lines: list[str], needle: str, label: str, start: int = 0) -> int:
    for i in range(start, len(lines)):
        if needle in lines[i]:
            return i
    fail(f"{label}: anchor containing {needle!r} not found")
    raise AssertionError("unreachable")


def insert_after_open_brace(lines: list[str], catch_index: int, statement: str, label: str) -> None:
    brace = None
    for i in range(catch_index, min(catch_index + 4, len(lines))):
        if "{" in lines[i]:
            brace = i
            break
    if brace is None:
        fail(f"{label}: opening brace not found")
    indent = lines[brace][: len(lines[brace]) - len(lines[brace].lstrip())] + "\t"
    lines.insert(brace + 1, indent + statement + "\n")


def resolve_init_catches(lines: list[str]) -> tuple[int, int, int]:
    init_start = unique_index(lines, "void GameEngine::init()", "GameEngine::init declaration")
    ini_idx = first_index(lines, "catch (INIException e)", "GameEngine init INIException", init_start)

    error_hits = [i for i in range(init_start, ini_idx) if "catch (ErrorCode ec)" in lines[i]]
    if len(error_hits) != 1:
        fail(f"GameEngine init ErrorCode catch: expected one before INI catch, found {len(error_hits)}")
    error_idx = error_hits[0]

    generic_idx = first_index(lines, "catch (...)" , "GameEngine init generic catch", ini_idx + 1)
    return error_idx, ini_idx, generic_idx


def main() -> int:
    if not CPP.is_file():
        fail(f"GameEngine.cpp not found: {CPP}")

    text = CPP.read_text(encoding="utf-8-sig")
    if MARKER in text:
        print("V7 diagnostic instrumentation already present; source left unchanged.")
        return 0

    lines = text.splitlines(keepends=True)

    # Validate every subsystem/action and catch anchor BEFORE mutating anything.
    for name, needle in GATES:
        unique_index(lines, needle, name)
    pre_idx = unique_index(lines, '#include "PreRTS.h"', "PreRTS include")
    resolve_init_catches(lines)

    backup = CPP.with_suffix(CPP.suffix + ".before_init_gate_v7.bak")
    if not backup.exists():
        shutil.copy2(CPP, backup)
        print(f"Backup: {backup}")

    lines.insert(pre_idx + 1, "\n" + HELPER + "\n")

    # Add BEGIN/OK around each post-ThingFactory operation. Work bottom-up so
    # insertions cannot move unprocessed anchors.
    resolved: list[tuple[str, int]] = []
    for name, needle in GATES:
        resolved.append((name, unique_index(lines, needle, name)))
    for name, idx in sorted(resolved, key=lambda item: item[1], reverse=True):
        indent = lines[idx][: len(lines[idx]) - len(lines[idx].lstrip())]
        lines.insert(idx + 1, indent + f'ZeroHour_Android_InitGate_Log("OK {name}");\n')
        lines.insert(idx, indent + f'ZeroHour_Android_InitGate_Log("BEGIN {name}");\n')

    error_idx, ini_idx, generic_idx = resolve_init_catches(lines)

    # Insert catch diagnostics from bottom to top so earlier indices stay valid.
    insert_after_open_brace(
        lines,
        generic_idx,
        'ZeroHour_Android_InitGate_Log("CATCH unknown exception during GameEngine::init");',
        "generic catch",
    )
    insert_after_open_brace(
        lines,
        ini_idx,
        'ZeroHour_Android_InitGate_Log(e.mFailureMessage ? e.mFailureMessage : "CATCH INIException (null message)");',
        "INIException catch",
    )
    insert_after_open_brace(
        lines,
        error_idx,
        'ZeroHour_Android_InitGate_LogCode("CATCH ErrorCode", static_cast<int>(ec));',
        "ErrorCode catch",
    )

    out = "".join(lines)
    required = [
        MARKER,
        'ZeroHour_Android_InitGate_Log("BEGIN UpgradeCenter")',
        'ZeroHour_Android_InitGate_Log("OK PostProcessLoadAll")',
        'ZeroHour_Android_InitGate_LogCode("CATCH ErrorCode"',
        "e.mFailureMessage ? e.mFailureMessage",
        'ZeroHour_Android_InitGate_Log("CATCH unknown exception during GameEngine::init")',
    ]
    for token in required:
        if token not in out:
            fail(f"post-patch verification missing token: {token}")

    CPP.write_text(out, encoding="utf-8", newline="")
    print("V7 Android-only init-gate diagnostics applied safely.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
