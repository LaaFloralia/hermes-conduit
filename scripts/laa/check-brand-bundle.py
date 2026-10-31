#!/usr/bin/env python3
"""Check display resources in the complete archived LAA app before export.

This checks generated resources and App Intents metadata, not arbitrary
runtime data or Swift literals. Unreadable resources and missing components
fail the check; source/UI review still covers fixed Swift and server content.
"""
import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

APP_ID = "com.laa-inc.laa"
REQUIRED = {APP_ID, APP_ID + ".widgets", APP_ID + ".ShareExtension",
            APP_ID + ".NotificationService", APP_ID + ".watchkitapp",
            APP_ID + ".watchkitapp.widgets"}
INTENTS = {APP_ID, APP_ID + ".watchkitapp", APP_ID + ".watchkitapp.widgets"}
BRAND = re.compile(r"Conduit|Hermes", re.I)

# Internal metadata names identify Swift types / intents and are not display
# strings. They are kept to preserve registered shortcuts and compatibility.
INTERNAL_METADATA_KEYS = {"identifier", "bundleidentifier", "typeidentifier", "typename",
                          "mangledtypename", "classname", "symbolname", "qualifiedtypename"}
# Whole links and App Group IDs are identifiers, not localizable display text;
# changing them would break existing deep links and shared storage.
INTERNAL_VALUE = re.compile(r"^(?:(?:https?|conduit|conduitwatch)://[^\s]+|group\.[A-Za-z0-9.-]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})$", re.I)


class CheckError(Exception):
    pass


def load_resource(path):
    data = path.read_bytes()
    try:
        return plistlib.loads(data)
    except (plistlib.InvalidFileException, ValueError):
        pass
    try:
        return json.loads(data)
    except (ValueError, UnicodeDecodeError):
        pass
    if path.suffix in {".strings", ".stringsdict", ".plist"}:
        try:
            result = subprocess.run(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(path)],
                                    capture_output=True, check=True)
            return plistlib.loads(result.stdout)
        except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException):
            pass
    raise CheckError(f"unreadable resource: {path}")


def scan_values(value, path, issues, key="", metadata=False):
    if isinstance(value, dict):
        for child_key, child in value.items():
            child_key = str(child_key)
            if metadata and child_key.lower() in INTERNAL_METADATA_KEYS:
                continue
            scan_values(child, path, issues, child_key, metadata)
    elif isinstance(value, list):
        for child in value:
            scan_values(child, path, issues, key, metadata)
    elif isinstance(value, str) and BRAND.search(value) and not INTERNAL_VALUE.fullmatch(value):
        # Print only the resource and key, never the value (which may contain
        # addresses or other data in a future generated resource).
        issues.append(f"old brand in {path} (key: {key})")


def bundle_info(bundle):
    path = bundle / "Info.plist"
    if not path.is_file():
        raise CheckError(f"missing Info.plist: {bundle}")
    info = load_resource(path)
    if not isinstance(info, dict):
        raise CheckError(f"invalid Info.plist: {bundle}")
    return info


def check_bundle(bundle):
    bundle = Path(bundle)
    if not bundle.is_dir() or bundle.suffix != ".app":
        raise CheckError("supply the archived LAA .app directory")
    root_info = bundle_info(bundle)
    if root_info.get("CFBundleIdentifier") != APP_ID:
        raise CheckError("the supplied app is not the LAA bundle")
    found = {APP_ID: bundle}
    for info_path in bundle.rglob("Info.plist"):
        if info_path.parent == bundle:
            continue
        info = load_resource(info_path)
        identifier = info.get("CFBundleIdentifier") if isinstance(info, dict) else None
        if identifier in REQUIRED:
            if identifier in found:
                raise CheckError(f"duplicate required bundle: {identifier}")
            found[identifier] = info_path.parent
    missing = REQUIRED - found.keys()
    if missing:
        raise CheckError("missing required bundles: " + ", ".join(sorted(missing)))

    issues = []
    for identifier, part in found.items():
        info = bundle_info(part)
        for key in ("CFBundleDisplayName", "CFBundleName"):
            if not isinstance(info.get(key), str) or not info[key]:
                raise CheckError(f"missing {key}: {part}")
        # These plist fields can be shown in permission, home-screen and
        # quick-action UI. Executable names, URL schemes and IDs are excluded.
        for key, value in info.items():
            if key in {"CFBundleDisplayName", "CFBundleName", "UIApplicationShortcutItems"} or (key.startswith("NS") and key.endswith("UsageDescription")):
                scan_values(value, part / "Info.plist", issues, key)
        localizations = list(part.glob("*.lproj/Localizable.strings"))
        if not localizations:
            raise CheckError(f"missing compiled localization: {part}")
        for folder in part.glob("*.lproj"):
            for pattern in ("*.strings", "*.stringsdict"):
                for resource in folder.glob(pattern):
                    scan_values(load_resource(resource), resource, issues)
        metadata = part / "Metadata.appintents"
        if identifier in INTENTS and not metadata.is_dir():
            raise CheckError(f"missing App Intents metadata: {part}")
        if metadata.is_dir():
            files = [path for path in metadata.rglob("*") if path.is_file()]
            if not files:
                raise CheckError(f"empty App Intents metadata: {part}")
            for resource in files:
                scan_values(load_resource(resource), resource, issues, metadata=True)
    return issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        issues = check_bundle(args.app)
    except (CheckError, OSError) as error:
        print(f"LAA branding check failed: {error}", file=sys.stderr)
        return 1
    if issues:
        for issue in issues:
            print(issue, file=sys.stderr)
        print(f"LAA branding check failed: {len(issues)} issue(s)", file=sys.stderr)
        return 1
    print("LAA branding check passed for app, extensions, Watch and widgets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
