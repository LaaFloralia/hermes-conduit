#!/usr/bin/env python3
"""Check that no LAA employee may call the owner on its own.

An employee calls when the owner asks for it (`when_asked`). Calling on its
own judgment (`decides`) and calling about approvals, questions and failed
turns (`alerts`) stay off until the owner turns them on. This reads each
profile's saved call settings and changes nothing.

    scripts/laa/check-call-policy.py [--profiles-dir DIR] [--json]

Exit 0 when every profile keeps both off, 1 when any has one on, 2 when a
settings file cannot be read.
"""
import argparse
import json
import sys
from pathlib import Path

# The notifier's own defaults for a profile that never saved its settings.
DEFAULTS = {"enabled": False, "when_asked": True, "decides": False, "alerts": False}
AUTONOMOUS = ("decides", "alerts")


def read_profile(directory: Path) -> dict:
    """One profile's call settings, with the notifier's defaults filled in."""
    file = directory / "conduit-calls.json"
    row = {"profile": directory.name, "saved": file.exists(), "error": None, **DEFAULTS}
    if not row["saved"]:
        return row
    try:
        settings = json.loads(file.read_text(encoding="utf-8")).get("settings")
        if not isinstance(settings, dict):
            raise ValueError("no settings object")
    except (OSError, ValueError) as error:
        row["error"] = type(error).__name__
        return row
    for key in DEFAULTS:
        if isinstance(settings.get(key), bool):
            row[key] = settings[key]
    return row


def check(profiles_dir: Path) -> dict:
    rows = [read_profile(path) for path in sorted(profiles_dir.glob("laa-*")) if path.is_dir()]
    violations = [
        {"profile": row["profile"], "setting": key}
        for row in rows if not row["error"]
        for key in AUTONOMOUS if row[key]
    ]
    unreadable = [row["profile"] for row in rows if row["error"]]
    return {"profiles": rows, "violations": violations, "unreadable": unreadable}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--profiles-dir", type=Path, default=Path.home() / ".hermes/profiles")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    result = check(args.profiles_dir)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=1))
    else:
        for row in result["profiles"]:
            state = "unreadable" if row["error"] else " ".join(f"{key}={'on' if row[key] else 'off'}" for key in DEFAULTS)
            print(f"{row['profile']}: {state}{'' if row['saved'] else ' (defaults)'}")
        for item in result["violations"]:
            print(f"VIOLATION {item['profile']}: {item['setting']} is on")
    if result["unreadable"]:
        return 2
    return 1 if result["violations"] else 0


if __name__ == "__main__":
    sys.exit(main())
