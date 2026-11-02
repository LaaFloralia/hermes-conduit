#!/usr/bin/env python3
"""Carry the three opt-in Bridge settings over a reinstall.

`scripts/install.sh` writes the LaunchAgent plist from the template, so any
setting an operator added by hand would disappear on reinstall. Only these
keys survive: everything else keeps coming from the template, so a setting
that was never opted into cannot switch itself on.

Values are copied inside this process and never printed.
"""

import plistlib
import sys

CARRIED = (
    "LAA_LINEAR_PERSONAL_TOKEN_HELPER",
    "LAA_LINEAR_PERSONAL_VIEWER_ID",
    "LAA_GOOGLE_REMINDERS_ENABLED",
)


def carried(old):
    env = old.get("EnvironmentVariables") if isinstance(old, dict) else None
    if not isinstance(env, dict):
        return {}
    return {key: value for key, value in env.items() if key in CARRIED}


def main(argv):
    if len(argv) != 3:
        print("usage: preserve-plist-env.py <previous-plist> <new-plist>", file=sys.stderr)
        return 2
    old_path, new_path = argv[1], argv[2]
    try:
        with open(old_path, "rb") as handle:
            previous = plistlib.load(handle)
    except (FileNotFoundError, plistlib.InvalidFileException, ValueError):
        # A first install, or a plist this script cannot read: keep the template.
        return 0
    kept = carried(previous)
    if not kept:
        return 0
    with open(new_path, "rb") as handle:
        current = plistlib.load(handle)
    env = dict(current.get("EnvironmentVariables") or {})
    env.update(kept)
    current["EnvironmentVariables"] = env
    with open(new_path, "wb") as handle:
        plistlib.dump(current, handle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
