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
MAC_REQUIRED = {APP_ID, APP_ID + ".NotificationService"}
INTENTS = {APP_ID, APP_ID + ".watchkitapp", APP_ID + ".watchkitapp.widgets"}
BRAND = re.compile(r"Conduit|Hermes", re.I)
NOTICE_NAME = "LAAOpenSourceNotices.txt"
NOTICE_SOURCE = Path(__file__).resolve().parents[2] / "assets/laa" / NOTICE_NAME

# Internal metadata names identify Swift types / intents and are not display
# strings. They are kept to preserve registered shortcuts and compatibility.
INTERNAL_METADATA_KEYS = {"identifier", "bundleidentifier", "typeidentifier", "typename",
                          "mangledtypename", "classname", "symbolname", "qualifiedtypename",
                          "fullyqualifiedtypename", "mangledtypenamev2", "autoshortcutprovidermangledname",
                          "actionidentifier", "defaultqueryidentifier", "entitytype",
                          "fullyqualifiedidentifier", "querytype"}
METADATA_IDENTIFIER = re.compile(r"[A-Za-z0-9_.$]+")
# Registered app links and App Group IDs are identifiers, not display copy.
# Do not exempt web links: an upstream web address in a compiled display
# value is still an upstream link, even when it is the entire value.
INTERNAL_VALUE = re.compile(r"^(?:(?:conduit|conduitwatch)://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%+-]+|group\.[A-Za-z0-9.-]+)$", re.I)
# The retained deep-link scheme can occur inside a model-facing prompt.
# Ignore only the link, never neighboring visible product names.
INTERNAL_LINK = re.compile(r"(?<![A-Za-z0-9_])conduit://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%+-]+", re.I)
# Xcode's shortcut YAML uses these type names to connect utterances to the
# already-registered intent. They are not words spoken or displayed to users.
YAML_INTERNAL_NAME = re.compile(r"\s*-?\s*name:\s*(?:SendToHermesIntent_\d+|ConduitProfileEntity)\s*")
YAML_PROFILE_PARAMETER = "${ConduitProfileEntity}"


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
            if (metadata and child_key.lower() in INTERNAL_METADATA_KEYS and isinstance(child, str)
                    and METADATA_IDENTIFIER.fullmatch(child)):
                continue
            scan_values(child, path, issues, child_key, metadata)
    elif isinstance(value, list):
        for child in value:
            scan_values(child, path, issues, key, metadata)
    elif isinstance(value, str) and not INTERNAL_VALUE.fullmatch(value) and BRAND.search(INTERNAL_LINK.sub("", value)):
        # Print only the resource and key, never the value (which may contain
        # addresses or other data in a future generated resource).
        issues.append(f"old brand in {path} (key: {key})")


def scan_shortcuts_yaml(path, issues):
    """Inspect Xcode's generated SSU YAML without a third-party parser.

    Reject escaped or unfamiliar input instead of missing a name hidden in an
    escape. Allow the registered parameter only inside shortcut utterances.
    """
    try:
        content = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise CheckError(f"unreadable resource: {path}") from error
    if not content.startswith("apiVersion: ssu/v1\n") or "\\" in content or "\t" in content:
        raise CheckError(f"unsupported shortcut YAML: {path}")
    utterance_indent = None
    for number, line in enumerate(content.splitlines(), 1):
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped)
        if stripped == "utterances:":
            utterance_indent = indent
        elif stripped and utterance_indent is not None and indent <= utterance_indent and not (indent == utterance_indent and stripped.startswith("- ")):
            utterance_indent = None
        if YAML_INTERNAL_NAME.fullmatch(line):
            continue
        if utterance_indent is not None and stripped.startswith("- "):
            line = line.replace(YAML_PROFILE_PARAMETER, "")
        if BRAND.search(INTERNAL_LINK.sub("", line)):
            issues.append(f"old brand in {path} (line: {number})")


def bundle_info(bundle):
    path = bundle / ("Contents/Info.plist" if (bundle / "Contents").is_dir() else "Info.plist")
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
    is_mac = (bundle / "Contents").is_dir()
    notices = (bundle / "Contents/Resources" if is_mac else bundle) / NOTICE_NAME
    if not notices.is_file() or notices.read_bytes() != NOTICE_SOURCE.read_bytes():
        raise CheckError("missing or altered open-source notices in the app")
    found = {APP_ID: bundle}
    # Inspect every embedded app and extension, not just today's known IDs:
    # adding another extension must not silently bypass the display check.
    for part in bundle.rglob("*"):
        if not part.is_dir() or part.suffix not in {".app", ".appex"}:
            continue
        info = bundle_info(part)
        identifier = info.get("CFBundleIdentifier")
        if not isinstance(identifier, str) or not identifier:
            raise CheckError(f"missing bundle identifier: {part}")
        if identifier in found:
            raise CheckError(f"duplicate bundle: {identifier}")
        found[identifier] = part
    missing = (MAC_REQUIRED if is_mac else REQUIRED) - found.keys()
    if missing:
        raise CheckError("missing required bundles: " + ", ".join(sorted(missing)))

    issues = []
    for identifier, part in found.items():
        info = bundle_info(part)
        resources = part / "Contents/Resources" if (part / "Contents").is_dir() else part
        for key in ("CFBundleDisplayName", "CFBundleName"):
            if not isinstance(info.get(key), str) or not info[key]:
                raise CheckError(f"missing {key}: {part}")
        # These plist fields can be shown in permission, home-screen and
        # quick-action UI. Executable names, URL schemes and IDs are excluded.
        for key, value in info.items():
            if key in {"CFBundleDisplayName", "CFBundleName", "UIApplicationShortcutItems"} or (key.startswith("NS") and key.endswith("UsageDescription")):
                scan_values(value, part / ("Contents/Info.plist" if resources != part else "Info.plist"), issues, key)
        localizations = list(resources.glob("*.lproj/Localizable.strings"))
        if not localizations:
            raise CheckError(f"missing compiled localization: {part}")
        for folder in resources.glob("*.lproj"):
            for pattern in ("*.strings", "*.stringsdict"):
                for resource in folder.glob(pattern):
                    scan_values(load_resource(resource), resource, issues)
        metadata = resources / "Metadata.appintents"
        if identifier in INTENTS and not metadata.is_dir():
            raise CheckError(f"missing App Intents metadata: {part}")
        if metadata.is_dir():
            files = [path for path in metadata.rglob("*") if path.is_file()]
            if not files:
                raise CheckError(f"empty App Intents metadata: {part}")
            for resource in files:
                if resource.name == "root.ssu.yaml":
                    scan_shortcuts_yaml(resource, issues)
                else:
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
