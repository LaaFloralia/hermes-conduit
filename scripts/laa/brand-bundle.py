#!/usr/bin/env python3
"""Brand only generated LAA bundles; source catalogs and lookup keys stay intact."""
import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path


def display(value):
    for old, new in (("Hermes Conduit", "LAA"), ("Conduit-chan", "Ciel"),
                     ("Conduit plugin", "Hermes plugin"), ("Conduit", "LAA")):
        value = value.replace(old, new)
    return value


def values_only(value):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            # The upstream developer and this fork's server operator differ.
            # Keep the translated destination and encryption sentence, but
            # do not transfer upstream's developer-visibility claim to LAA.
            if isinstance(item, str) and "Conduit's developer can't see it." in key:
                item = re.split(r"(?<=[.。])\s*", item, maxsplit=1)[0]
            result[key] = values_only(item)
        return result
    if isinstance(value, list):
        return [values_only(item) for item in value]
    return display(value) if isinstance(value, str) else value


def read_plist(path):
    try:
        with path.open("rb") as stream:
            return plistlib.load(stream)
    except plistlib.InvalidFileException:
        xml = subprocess.check_output(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(path)])
        return plistlib.loads(xml)


def permission_strings(catalog, locale):
    result = {}
    for key, entry in catalog["strings"].items():
        localizations = entry.get("localizations", {})
        english = localizations["en"]["stringUnit"]["value"]
        text = localizations.get(locale, localizations["en"])["stringUnit"]["value"]
        # The upstream developer is distinct from the operator of this fork.
        # Remove that last sentence rather than assert that LAA receives none.
        if "Nothing goes to Conduit's developer." in english:
            match = re.match(r"^(.*[.。])\s*([^。.!?]*Conduit[^。.!?]*[.。])$", text, re.S)
            if not match:
                raise ValueError(f"Cannot isolate upstream-developer sentence for {key}/{locale}")
            text = match.group(1).strip()
        result[key] = display(text)
    return result


def brand_bundle(bundle, kind, source):
    names = {"app": "LAA", "watch": "LAA", "watch-widget": "LAA Watch Widgets",
             "widgets": "LAA Widgets", "notification": "LAA Notifications", "share": "LAA"}
    info_path = bundle / "Info.plist"
    info = read_plist(info_path)
    info["CFBundleDisplayName"] = names[kind]
    if kind in ("app", "watch"):
        catalog_path = source / ("Conduit/InfoPlist.xcstrings" if kind == "app" else "ConduitWatch/InfoPlist.xcstrings")
        catalog = json.loads(catalog_path.read_text())
        info.update(permission_strings(catalog, "en"))
        locales = {p.stem for p in bundle.glob("*.lproj")} | {"en", "ja"}
        for locale in locales:
            directory = bundle / (locale + ".lproj")
            directory.mkdir(exist_ok=True)
            with (directory / "InfoPlist.strings").open("wb") as stream:
                plistlib.dump(permission_strings(catalog, locale), stream, fmt=plistlib.FMT_BINARY)
    with info_path.open("wb") as stream:
        plistlib.dump(info, stream, fmt=plistlib.FMT_BINARY, sort_keys=False)
    for directory in bundle.glob("*.lproj"):
        for pattern in ("*.strings", "*.stringsdict"):
            for path in directory.glob(pattern):
                if path.name == "InfoPlist.strings":
                    continue
                data = read_plist(path)
                with path.open("wb") as stream:
                    plistlib.dump(values_only(data), stream, fmt=plistlib.FMT_BINARY, sort_keys=False)

    # String catalogs omit untranslated source-language entries from en.lproj.
    # Without explicit English values, Foundation displays the original key.
    catalog_path = source / ("ConduitWatch/Localizable.xcstrings"
                             if kind in ("watch", "watch-widget") else "Conduit/Localizable.xcstrings")
    catalog = json.loads(catalog_path.read_text())["strings"]
    english_dir = bundle / "en.lproj"
    english_dir.mkdir(exist_ok=True)
    english_path = english_dir / "Localizable.strings"
    english = read_plist(english_path) if english_path.exists() else {}
    for key in catalog:
        if "Conduit" in key and key not in english:
            english[key] = values_only({key: key})[key]
    with english_path.open("wb") as stream:
        plistlib.dump(english, stream, fmt=plistlib.FMT_BINARY, sort_keys=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--kind", required=True, choices=("app", "watch", "watch-widget", "widgets", "notification", "share"))
    parser.add_argument("--source", required=True, type=Path)
    args = parser.parse_args()
    brand_bundle(args.bundle, args.kind, args.source)


if __name__ == "__main__":
    main()
