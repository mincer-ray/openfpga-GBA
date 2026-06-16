#!/usr/bin/env python3
"""Generate an mGBA suite test-name manifest for benchmark save rehydration."""

from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
from pathlib import Path
from typing import Any


SUITES = [
    ("memory", "memoryTests", "memoryTestSuite"),
    ("io-read", "ioReadTests", "ioReadTestSuite"),
    ("timing", "timingTests", "timingTestSuite"),
    ("timers", "timerTests", "timersTestSuite"),
    ("timer-irq", "timerIRQTests", "timerIRQTestSuite"),
    ("shifter", "shifterTests", "shifterTestSuite"),
    ("carry", "carryTests", "carryTestSuite"),
    ("multiply-long", "multiplyLongTests", "multiplyLongTestSuite"),
    ("bios-math", "mathTests", "biosMathTestSuite"),
    ("dma", "dmaTests", "dmaTestSuite"),
    ("sio-read", "sioReadTests", "sioReadTestSuite"),
    ("sio-timing", "sioTimingTests", "sioTimingTestSuite"),
    ("misc-edge", "miscEdgeTests", "miscEdgeTestSuite"),
    ("video", "videoTests", "videoTestSuite"),
]


def strip_comments(text: str) -> str:
    output: list[str] = []
    i = 0
    in_string = False
    in_char = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_string:
            output.append(ch)
            if ch == "\\" and nxt:
                output.append(nxt)
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if in_char:
            output.append(ch)
            if ch == "\\" and nxt:
                output.append(nxt)
                i += 2
                continue
            if ch == "'":
                in_char = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            output.append(ch)
            i += 1
            continue
        if ch == "'":
            in_char = True
            output.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            i = text.find("\n", i)
            if i == -1:
                break
            output.append("\n")
            i += 1
            continue
        if ch == "/" and nxt == "*":
            end = text.find("*/", i + 2)
            i = len(text) if end == -1 else end + 2
            continue
        output.append(ch)
        i += 1
    return "".join(output)


def brace_body_after(text: str, marker: str) -> str:
    start = text.find(marker)
    if start == -1:
        raise ValueError(f"could not find {marker}")
    brace = text.find("{", start)
    if brace == -1:
        raise ValueError(f"could not find opening brace for {marker}")
    depth = 0
    in_string = False
    for i in range(brace, len(text)):
        ch = text[i]
        prev = text[i - 1] if i else ""
        if ch == '"' and prev != "\\":
            in_string = not in_string
        if in_string:
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : i]
    raise ValueError(f"could not find closing brace for {marker}")


def top_level_entries(body: str) -> list[str]:
    entries: list[str] = []
    depth = 0
    in_string = False
    start: int | None = None
    for i, ch in enumerate(body):
        prev = body[i - 1] if i else ""
        if ch == '"' and prev != "\\":
            in_string = not in_string
        if in_string:
            continue
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                entries.append(body[start : i + 1])
                start = None
    return entries


def first_c_string(text: str) -> str:
    match = re.search(r'"(?:\\.|[^"\\])*"', text)
    if not match:
        raise ValueError(f"could not find string in entry: {text[:80]}")
    return ast.literal_eval(match.group(0))


def suite_name(text: str, suite_symbol: str) -> str:
    body = brace_body_after(text, f"const struct TestSuite {suite_symbol}")
    match = re.search(r"\.name\s*=\s*(\"(?:\\.|[^\"\\])*\")", body)
    if not match:
        raise ValueError(f"could not find .name for {suite_symbol}")
    return ast.literal_eval(match.group(1))


def git_commit(path: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"],
        text=True,
    ).strip()


def generate(suite_repo: Path) -> dict[str, Any]:
    suites: list[dict[str, Any]] = []
    for suite_id, (source_stem, array_name, suite_symbol) in enumerate(SUITES):
        path = suite_repo / "src" / f"{source_stem}.c"
        text = strip_comments(path.read_text())
        body = brace_body_after(text, f"{array_name}[]")
        names = [first_c_string(entry) for entry in top_level_entries(body)]
        suites.append(
            {
                "id": suite_id,
                "name": suite_name(text, suite_symbol),
                "array": array_name,
                "source": str(path.relative_to(suite_repo)),
                "tests": names,
            }
        )
    return {
        "suite_commit": git_commit(suite_repo),
        "suites": suites,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--suite-repo",
        type=Path,
        default=Path("reference/repos/mgba-suite"),
        help="Path to mgba-emu/suite checkout",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("benchmarks/mgba-suite/test-manifest.json"),
        help="Manifest output path",
    )
    args = parser.parse_args()

    manifest = generate(args.suite_repo)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
