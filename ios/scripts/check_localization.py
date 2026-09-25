#!/usr/bin/env python3
"""Fails when a user-facing string has no Vietnamese translation.

The compiler writes every localizable key it finds into .stringsdata files
during a build. Comparing those against Localizable.xcstrings catches the
failure mode a test cannot see: someone adds `Text("New button")`, ships it,
and a seller who chose Tiếng Việt reads one English word in the middle of a
Vietnamese screen.

Keys may be exempted by listing them in the catalog with no localizations —
a brand name, a pure format string, a separator. That is a deliberate entry,
not an omission.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys


def keys_from_build(objects_dir: pathlib.Path) -> dict[str, str]:
    """Every localizable key the compiler emitted, mapped to its source file."""
    found: dict[str, str] = {}
    for path in sorted(objects_dir.glob("*.stringsdata")):
        try:
            data = json.loads(path.read_text())
        except (ValueError, OSError):
            continue  # Not every .stringsdata is a Swift table.
        source = pathlib.Path(data.get("source", path.name)).name
        for entries in data.get("tables", {}).values():
            for entry in entries:
                found.setdefault(entry["key"], source)
    return found


def catalog(path: pathlib.Path) -> dict[str, dict]:
    return json.loads(path.read_text())["strings"]


def untranslated(build_keys: dict[str, str], strings: dict[str, dict], language: str) -> list[str]:
    missing = []
    for key, source in sorted(build_keys.items()):
        entry = strings.get(key)
        if entry is None:
            missing.append(f"{key!r} ({source}) is not in the catalog at all")
            continue
        localizations = entry.get("localizations", {})
        if not localizations:
            continue  # Deliberately left as written in both languages.
        unit = localizations.get(language, {}).get("stringUnit", {})
        if unit.get("state") != "translated" or not unit.get("value"):
            missing.append(f"{key!r} ({source}) has no {language} translation")
    return missing


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", required=True, type=pathlib.Path)
    parser.add_argument("--objects", required=True, type=pathlib.Path,
                        help="Build directory holding the .stringsdata files.")
    parser.add_argument("--language", default="vi")
    args = parser.parse_args()

    build_keys = keys_from_build(args.objects)
    if not build_keys:
        print(f"No .stringsdata under {args.objects}. Build the app first.", file=sys.stderr)
        return 2

    missing = untranslated(build_keys, catalog(args.catalog), args.language)
    if missing:
        print(f"{len(missing)} string(s) would show in English to a {args.language} seller:", file=sys.stderr)
        for line in missing:
            print(f"  {line}", file=sys.stderr)
        return 1

    print(f"All {len(build_keys)} localizable strings are covered in {args.language}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
