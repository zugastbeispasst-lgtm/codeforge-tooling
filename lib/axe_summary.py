#!/usr/bin/env python3
"""
axe_summary.py — parse an @axe-core/cli JSON report and print the violation count.

Used by browser-check.sh to tell a REAL accessibility violation apart from a
Chrome/driver CRASH: axe-cli exits 1 in both cases, but only a genuine run
writes a parseable report (rework #1, finding 3). It also asserts that the
axe-core engine version recorded in the report matches the pinned expectation
so a silent engine drift cannot slip through (rework #1, finding 5).

Usage:
  axe_summary.py <report.json> [expected_axe_core_version]

stdout: integer violation count (only on exit 0).
Exit codes:
  0  report parsed; engine version matches the pin (if one was supplied).
  3  engine version mismatch vs the expected pin.
  4  report missing, empty, or unparseable.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("axe_summary: usage: axe_summary.py <report.json> [expected_version]", file=sys.stderr)
        return 4
    path = sys.argv[1]
    expected = sys.argv[2] if len(sys.argv) > 2 else ""

    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        print(f"axe_summary: report not found: {path}", file=sys.stderr)
        return 4
    except (OSError, ValueError) as exc:
        print(f"axe_summary: cannot parse report {path}: {exc}", file=sys.stderr)
        return 4

    # axe-cli --save writes a list of results (one per audited URL); be lenient
    # about a single-object report too.
    results = data if isinstance(data, list) else [data]
    results = [r for r in results if isinstance(r, dict)]
    if not results:
        print("axe_summary: report contains no results", file=sys.stderr)
        return 4

    versions = set()
    total = 0
    for res in results:
        engine = res.get("testEngine") or {}
        version = engine.get("version")
        if version:
            versions.add(str(version))
        total += len(res.get("violations") or [])

    if expected and versions and versions != {expected}:
        print(
            f"axe_summary: axe-core version {sorted(versions)} != pinned {expected}",
            file=sys.stderr,
        )
        return 3

    print(total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
