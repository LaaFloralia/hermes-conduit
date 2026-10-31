#!/usr/bin/env python3
"""Brand only generated LAA bundles; source catalogs and lookup keys stay intact."""
import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path

# Each target's default home-screen name. A build that needs another one (the
# personal build keeps upstream's identity) passes --name.
names = {"app": "LAA", "watch": "LAA", "watch-widget": "LAA Watch Widgets",
         "widgets": "LAA Widgets", "notification": "LAA Notifications", "share": "LAA"}

# A value that is an identifier, link or address keeps its spelling: only
# display copy is rebranded (BUS-330).
identifier = re.compile(r"^(?:[A-Za-z0-9_.:/@+-]+[._:/@+][A-Za-z0-9_.:/@+-]*|Conduit[A-Za-z0-9]*[A-Z][A-Za-z0-9]*)$")


def is_identifier(value):
    # "ConduitAppGroup" is a symbol; "Conduitを開く" is a sentence, and its
    # format specifier (%2$@) must not read as an address.
    return not any(c.isspace() for c in value) and identifier.match(value) is not None


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
    if not isinstance(value, str):
        return value
    return value if is_identifier(value) else display(value)


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


def brand_bundle(bundle, kind, source, name=None, bundle_name=None):
    info_path = bundle / "Info.plist"
    info = read_plist(info_path)
    info["CFBundleDisplayName"] = name or names[kind]
    if bundle_name:
        info["CFBundleName"] = bundle_name
    if kind in ("app", "watch"):
        catalog_path = source / ("Conduit/InfoPlist.xcstrings" if kind == "app" else "ConduitWatch/InfoPlist.xcstrings")
        catalog = json.loads(catalog_path.read_text())
        info.update(permission_strings(catalog, "en"))
        # Update the localizations the build already produced, and never
        # create one: a draft language strip-draft-localizations.py removed
        # would come back. English needs no lproj; the base Info.plist has it.
        for path in bundle.glob("*.lproj/InfoPlist.strings"):
            strings = read_plist(path)
            strings.update(permission_strings(catalog, path.parent.stem))
            with path.open("wb") as stream:
                plistlib.dump(strings, stream, fmt=plistlib.FMT_BINARY)
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
    parser.add_argument("--kind", required=True, choices=tuple(names))
    parser.add_argument("--source", required=True, type=Path)
    # The home-screen name: the personal build keeps its own identity beside
    # the LAA one, and an env override is honored instead of ignored.
    parser.add_argument("--name")
    parser.add_argument("--bundle-name")
    args = parser.parse_args()
    brand_bundle(args.bundle, args.kind, args.source, name=args.name, bundle_name=args.bundle_name)


if __name__ == "__main__":
    main()
