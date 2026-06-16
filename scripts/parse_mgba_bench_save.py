#!/usr/bin/env python3
"""Parse an autorun mGBA suite benchmark report from a GBA .sav file."""

from __future__ import annotations

import argparse
import csv
import json
import re
import struct
import sys
import zlib
from collections import OrderedDict
from pathlib import Path
from typing import Any


MAGIC = b"GBA_BENCH_V1" + b"\0" * 4
HEADER_SIZE = 0x20
FLAG_TRUNCATED = 0x00000001
GOT_RE = re.compile(r"\bGot (?P<actual>.*?) (?P<operator>vs|!=) (?P<expected>.*?)(?:: FAIL)?$")
DEFAULT_MANIFEST = Path(__file__).resolve().parents[1] / "benchmarks/mgba-suite/test-manifest.json"


class BenchParseError(ValueError):
    """Raised when a save does not contain a valid benchmark report."""


def read_u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def parse_payload(payload: bytes) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    records: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    text = payload.decode("utf-8", errors="replace")

    for line_no, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        if line.startswith("{"):
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                errors.append({"line": line_no, "error": str(exc), "text": line})
                continue
        else:
            try:
                record = parse_line_record(line)
            except BenchParseError as exc:
                errors.append({"line": line_no, "error": str(exc), "text": line})
                continue
        if not isinstance(record, dict):
            errors.append({"line": line_no, "error": "record is not an object", "text": line})
            continue
        records.append(record)

    return records, errors


def parse_line_record(line: str) -> dict[str, Any]:
    kind = line.split(" ", 1)[0]
    if kind == "m":
        parts = line.split(" ", 3)
        if len(parts) != 4:
            raise BenchParseError("invalid meta record")
        return {"t": "m", "v": int(parts[1]), "f": parts[2], "c": parts[3]}
    if kind == "s":
        parts = line.split(" ", 5)
        if len(parts) != 6:
            raise BenchParseError("invalid suite record")
        return {
            "t": "s",
            "s": int(parts[1]),
            "c": int(parts[2]),
            "p": int(parts[3]),
            "r": int(parts[4]),
            "b": parts[5],
        }
    if kind == "f":
        parts = line.split(" ", 4)
        if len(parts) != 5:
            raise BenchParseError("invalid failure record")
        return {
            "t": "f",
            "s": int(parts[1]),
            "i": int(parts[2]),
            "u": int(parts[3]),
            "m": parts[4],
        }
    if kind == "t":
        parts = line.split(" ", 3)
        if len(parts) != 4:
            raise BenchParseError("invalid totals record")
        return {"t": "t", "p": int(parts[1]), "r": int(parts[2]), "x": bool(int(parts[3]))}
    if kind == "d" and line == "d":
        return {"t": "d"}
    raise BenchParseError("unknown line-format record")


def load_manifest(path: Path | None) -> dict[str, Any]:
    if path is None:
        path = DEFAULT_MANIFEST
    if not path.exists():
        return {"suites": []}
    return json.loads(path.read_text())


def manifest_suite_map(manifest: dict[str, Any]) -> dict[int, dict[str, Any]]:
    suites = manifest.get("suites", [])
    return {
        suite["id"]: suite
        for suite in suites
        if isinstance(suite, dict) and isinstance(suite.get("id"), int)
    }


def bitset_failed_tests(bitset: str, count: int, names: list[str]) -> list[dict[str, Any]]:
    failed: list[dict[str, Any]] = []
    for index in range(count):
        nibble_index = index // 4
        bit = index % 4
        passed = False
        if nibble_index < len(bitset):
            passed = bool(int(bitset[nibble_index], 16) & (1 << bit))
        if not passed:
            failed.append({
                "id": index,
                "name": names[index] if index < len(names) else None,
            })
    return failed


def is_record_type(record: dict[str, Any], verbose: str, compact: str) -> bool:
    return record.get("type") == verbose or record.get("t") == compact


def first_present(record: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in record:
            return record[key]
    return None


def normalize_suite(record: dict[str, Any]) -> dict[str, Any]:
    if record.get("type") == "suite":
        return record
    return {
        "type": "suite",
        "suite_id": record.get("s"),
        "name": record.get("n"),
        "tests": record.get("c"),
        "passes": record.get("p"),
        "total": record.get("r"),
        "bitset": record.get("b"),
    }


def parse_save(
    path: Path,
    include_events: bool = False,
    manifest_path: Path | None = None,
) -> dict[str, Any]:
    data = path.read_bytes()
    if len(data) < HEADER_SIZE:
        raise BenchParseError(f"{path} is too small to contain a benchmark header")
    if data[: len(MAGIC)] != MAGIC:
        raise BenchParseError(
            f"{path} does not start with GBA_BENCH_V1; expected an autorun benchmark save"
        )

    payload_length = read_u32(data, 0x10)
    expected_crc = read_u32(data, 0x14)
    flags = read_u32(data, 0x18)
    payload_offset = read_u32(data, 0x1C)

    if payload_offset < HEADER_SIZE:
        raise BenchParseError(f"invalid payload offset 0x{payload_offset:08X}")
    payload_end = payload_offset + payload_length
    if payload_end > len(data):
        raise BenchParseError(
            f"payload extends past save file: offset 0x{payload_offset:X} length 0x{payload_length:X}"
        )

    payload = data[payload_offset:payload_end]
    actual_crc = zlib.crc32(payload) & 0xFFFFFFFF
    if actual_crc != expected_crc:
        raise BenchParseError(
            f"CRC mismatch: header 0x{expected_crc:08X}, computed 0x{actual_crc:08X}"
        )

    records, record_errors = parse_payload(payload)
    manifest = load_manifest(manifest_path)
    manifest_suites = manifest_suite_map(manifest)
    meta = next((record for record in records if is_record_type(record, "meta", "m")), {})
    totals = next((record for record in records if is_record_type(record, "totals", "t")), {})
    done = any(is_record_type(record, "done", "d") for record in records)
    truncated = bool(flags & FLAG_TRUNCATED) or bool(first_present(totals, "truncated", "x"))

    suites = [
        normalize_suite(record)
        for record in records
        if is_record_type(record, "suite", "s")
    ]
    for suite in suites:
        suite_manifest = manifest_suites.get(suite.get("suite_id"), {})
        if suite.get("name") is None:
            suite["name"] = suite_manifest.get("name")
        bitset = suite.get("bitset")
        if isinstance(bitset, str) and isinstance(suite.get("tests"), int):
            suite["failed_tests"] = bitset_failed_tests(
                bitset,
                suite["tests"],
                suite_manifest.get("tests", []),
            )
    suites_by_id = {
        record.get("suite_id"): record
        for record in suites
        if isinstance(record.get("suite_id"), int)
    }
    failures = merge_failures(records, suites_by_id, manifest_suites)

    passed = first_present(totals, "passes", "p")
    total = first_present(totals, "total", "r")
    failed = None
    if isinstance(passed, int) and isinstance(total, int):
        failed = max(0, total - passed)

    complete = bool(done and not truncated and not record_errors)
    summary: dict[str, Any] = {
        "path": str(path),
        "size": len(data),
        "schema": first_present(meta, "schema", "v"),
        "format": first_present(meta, "format", "f"),
        "suite_commit": first_present(meta, "suite_commit", "c"),
        "manifest": {
            "path": str(manifest_path or DEFAULT_MANIFEST),
            "suite_commit": manifest.get("suite_commit"),
            "loaded": bool(manifest.get("suites")),
        },
        "payload": {
            "offset": payload_offset,
            "length": payload_length,
            "crc32": f"0x{expected_crc:08X}",
            "flags": flags,
            "truncated": truncated,
            "records": len(records),
        },
        "complete": complete,
        "done": done,
        "record_errors": record_errors,
        "totals": {
            "passed": passed,
            "failed": failed,
            "total": total,
            "truncated": truncated,
        },
        "suites": suites,
        "failures": failures,
    }
    if include_events:
        summary["events"] = records
    return summary


def merge_failures(
    records: list[dict[str, Any]],
    suites_by_id: dict[int, dict[str, Any]],
    manifest_suites: dict[int, dict[str, Any]],
) -> list[dict[str, Any]]:
    merged: OrderedDict[tuple[Any, Any, Any], dict[str, Any]] = OrderedDict()

    for record in records:
        compact_failure = record.get("t") == "f"
        verbose_failure = record.get("type") in {"debug", "sav"} and record.get("failure")
        if not compact_failure and not verbose_failure:
            continue
        suite_id = first_present(record, "suite_id", "s")
        test_id = first_present(record, "test_id", "i")
        subtest_id = first_present(record, "subtest_id", "u")
        key = (suite_id, test_id, subtest_id)
        suite = suites_by_id.get(suite_id, {})
        item = merged.setdefault(
            key,
            {
                "suite_id": suite_id,
                "suite": suite.get("name"),
                "test_id": test_id,
                "subtest_id": subtest_id,
                "messages": [],
                "details": [],
            },
        )

        message = str(first_present(record, "message", "m") or "")
        if record.get("type") == "debug":
            item["messages"].append(message)
            if message.startswith("FAIL: "):
                item.setdefault("test", message[6:])
        else:
            item["details"].append(message)
            test_name = (
                manifest_test_name(manifest_suites, suite_id, test_id)
                or suite_failed_test_name(suite, test_id)
            )
            if test_name is not None:
                item.setdefault("test", test_name)
            parsed = parse_got_message(message)
            if parsed:
                item.setdefault("actual", parsed["actual"])
                item.setdefault("expected", parsed["expected"])
                item.setdefault("operator", parsed["operator"])

    return list(merged.values())


def manifest_test_name(
    manifest_suites: dict[int, dict[str, Any]], suite_id: Any, test_id: Any
) -> str | None:
    if not isinstance(suite_id, int) or not isinstance(test_id, int):
        return None
    tests = manifest_suites.get(suite_id, {}).get("tests", [])
    if test_id < 0 or test_id >= len(tests):
        return None
    test_name = tests[test_id]
    return test_name if isinstance(test_name, str) else None


def suite_failed_test_name(suite: dict[str, Any], test_id: Any) -> str | None:
    if not isinstance(test_id, int):
        return None
    for test in suite.get("failed_tests", []):
        if test.get("id") == test_id and isinstance(test.get("name"), str):
            return test["name"]
    return None


def parse_got_message(message: str) -> dict[str, str] | None:
    match = GOT_RE.search(message)
    if not match:
        return None
    return match.groupdict()


def print_text(summary: dict[str, Any]) -> None:
    totals = summary["totals"]
    print(f"file: {summary['path']}")
    print(f"schema: {summary.get('schema')} ({summary.get('format')})")
    print(f"suite commit: {summary.get('suite_commit')}")
    print(
        "payload: "
        f"{summary['payload']['length']} bytes, "
        f"{summary['payload']['records']} records, "
        f"crc {summary['payload']['crc32']}"
    )
    print(f"complete: {summary['complete']}")
    print(
        "totals: "
        f"{totals.get('passed')}/{totals.get('total')} passed, "
        f"{totals.get('failed')} failed"
    )
    if totals.get("truncated"):
        print("warning: report marked truncated")
    if summary["record_errors"]:
        print(f"warning: {len(summary['record_errors'])} malformed payload records")
    print()

    for suite in summary["suites"]:
        failed = None
        if isinstance(suite.get("passes"), int) and isinstance(suite.get("total"), int):
            failed = max(0, suite["total"] - suite["passes"])
        print(
            f" - {suite.get('name')}: "
            f"{suite.get('passes')}/{suite.get('total')} passed"
            + (f", {failed} failed" if failed is not None else "")
        )

    if summary["failures"]:
        print()
        print("failures:")
        for failure in summary["failures"][:20]:
            label = failure.get("test") or "; ".join(failure["messages"]) or "unknown"
            detail = "; ".join(failure["details"])
            print(
                f" - {failure.get('suite') or failure.get('suite_id')} "
                f"test {failure.get('test_id')} subtest {failure.get('subtest_id')}: {label}"
            )
            if detail:
                print(f"   {detail}")
        if len(summary["failures"]) > 20:
            print(f"   ... +{len(summary['failures']) - 20} more")


def print_csv(summary: dict[str, Any]) -> None:
    writer = csv.DictWriter(
        sys.stdout,
        fieldnames=[
            "suite",
            "suite_id",
            "test",
            "test_id",
            "subtest_id",
            "actual",
            "expected",
            "operator",
            "messages",
            "details",
        ],
    )
    writer.writeheader()
    for failure in summary["failures"]:
        writer.writerow(
            {
                "suite": failure.get("suite"),
                "suite_id": failure.get("suite_id"),
                "test": failure.get("test"),
                "test_id": failure.get("test_id"),
                "subtest_id": failure.get("subtest_id"),
                "actual": failure.get("actual"),
                "expected": failure.get("expected"),
                "operator": failure.get("operator"),
                "messages": " | ".join(failure["messages"]),
                "details": " | ".join(failure["details"]),
            }
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("save", type=Path, help="Path to the benchmark .sav file")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="Emit JSON summary")
    output.add_argument("--csv", action="store_true", help="Emit failure CSV")
    parser.add_argument("--events", action="store_true", help="Include raw payload records in JSON output")
    parser.add_argument(
        "--manifest",
        type=Path,
        help=f"Path to test-name manifest (default: {DEFAULT_MANIFEST})",
    )
    parser.add_argument(
        "--allow-incomplete",
        action="store_true",
        help="Exit 0 even if the report is truncated or missing the done marker",
    )
    args = parser.parse_args()

    try:
        summary = parse_save(args.save, include_events=args.events, manifest_path=args.manifest)
    except BenchParseError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(summary, indent=2))
    elif args.csv:
        print_csv(summary)
    else:
        print_text(summary)

    if not summary["complete"] and not args.allow_incomplete:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
