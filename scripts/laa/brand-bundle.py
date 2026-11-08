#!/usr/bin/env python3
"""Brand only generated LAA bundles; source catalogs and lookup keys stay intact."""
import argparse
import json
import plistlib
import re
import subprocess
import unicodedata
from pathlib import Path
from xml.parsers.expat import ExpatError

# Each target's default home-screen name. A build that needs another one (the
# personal build uses a distinct LAA name) passes --name.
names = {"app": "LAA", "watch": "LAA", "watch-widget": "LAA Watch Widgets",
         "widgets": "LAA Widgets", "notification": "LAA Notifications", "share": "LAA"}
# CFBundleName can also be displayed by the system. Keep executable names,
# bundle IDs and on-disk paths untouched; only supply short visible names.
bundle_names = {"watch": "LAA Watch", "watch-widget": "LAA Watch",
                "widgets": "LAA Widgets", "notification": "LAA Notices", "share": "LAA Share"}

# These are catalog keys, not runtime data. Their upstream display copy
# contains shell commands or internal configuration names that do not belong
# in the LAA interface. Keep the original keys and localize the replacement.
COPY = json.loads(Path(__file__).with_name("brand-copy.json").read_text())
STATIC_COPY_KEYS = {
    "Run hermes gateway status on the host to see why.": "check_mac",
    "It may still be finishing running tasks. Run hermes gateway status on the host to check.": "check_mac",
    "Update Hermes, or run hermes gateway restart on the host.": "check_mac",
    "The plugin is updated, but the gateway didn't come back. Run hermes gateway status on the host.": "check_mac",
    "On the host, `hermes conduit-push prefs export` and `prefs import` move the same set between hosts.": "sync_mac",
    "Set DASHSCOPE_API_KEY and CONDUIT_QWEN_LIVE_WORKSPACE on your Hermes profile. The permanent key stays on your server.": "qwen",
    "Your host has no fast model set (auxiliary.conduit_predict), so the chat's own model answers.": "fast_model",
    "GPT-Live calls will use your Hermes server's OpenAI API key, which OpenAI bills per minute of call time, separately from any ChatGPT plan. Your Hermes server has to allow it too (voice.gpt_live.conduit_api_billing in the profile's config).": "billing",
}
MAC_ONLY_KEYS = {"hermes chat on the host"}
EXAMPLE_KEYS = {
    "That doesn’t look like a dashboard URL Conduit can use. Check it for typos — it should look like https://hermes.example.",
    "Your existing HTTPS Hermes dashboard URL — for example https://hermes.example.com, https://hermes.example.com:9443, or https://example.com/hermes.",
}

# A value that is an identifier, link or address keeps its spelling: only
# display copy is rebranded (BUS-330).
def is_identifier(value):
    # Match specific forms, not arbitrary punctuation: "Conduit." and
    # "Conduit/LAA" can be display text; conduit:// is an internal link.
    return bool(re.fullmatch(r"(?:https?://|conduit://)[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%+-]+", value, re.I)
                or re.fullmatch(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", value)
                or re.fullmatch(r"group\.[A-Za-z0-9.-]+", value)
                or re.fullmatch(r"(?:Conduit|Hermes)[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*", value))


def validate_name(value):
    if (not value or value != value.strip() or len(value) > 64 or "/" in value
            or any(unicodedata.category(char) == "Cc" for char in value)
            or re.search(r"conduit|hermes", value, re.I)):
        raise ValueError("name must be 1–64 visible characters without surrounding whitespace, '/' or upstream names")
    return value


def validate_bundle_name(value):
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,15}", value)
            or value != value.strip() or re.search(r"conduit|hermes", value, re.I)):
        raise ValueError("bundle name must be 1–16 ASCII letters, digits, spaces, dots, underscores or hyphens, without upstream names")
    return value


def display(value, source_key=None, locale="en"):
    if source_key in {"Conduit profile", "LAA profile"} and locale == "ja":
        return "AI社員"
    # Transform app-owned display values only; lookup keys remain upstream's.
    for old, new in (("Hermes Conduit", "LAA"), ("Conduit-chan", "Ciel"),
                     ("Conduit notifier plugin", "LAA plugin"),
                     ("Conduit plugin", "LAA plugin"),
                     ("Hermes notifier plugin", "LAA plugin"),
                     ("Conduit プラグイン", "LAAの連携プラグイン"),
                     ("Conduitプラグイン", "LAAの連携プラグイン"),
                     ("Hermes プラグイン", "LAAの連携プラグイン"),
                     ("Hermesプラグイン", "LAAの連携プラグイン"),
                     ("Hermes gateway", "LAA background service"),
                     ("Hermesのgateway", "LAAの常駐サービス"),
                     ("Hermesゲートウェイ", "LAAの常駐サービス"),
                     ("Hermes profile", "AI employee"),
                     ("Conduit profile", "AI employee"),
                     ("LAA profile", "AI employee"),
                     ("Hermesのプロファイル", "AI社員"),
                     ("Hermesプロファイル", "AI社員"),
                     ("Hermes cron", "scheduled runs"),
                     ("Hermes", "LAA"), ("Conduit", "LAA"),
                     ("Paseo", "Work"), ("パセオ", "Work")):
        value = value.replace(old, new)
    return value


def values_only(value, source_key=None, locale="en"):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            # The upstream developer and this fork's server operator differ.
            # Keep the translated destination and encryption sentence, but
            # do not transfer upstream's developer-visibility claim to LAA.
            if isinstance(item, str) and "Conduit's developer can't see it." in key:
                item = re.split(r"(?<=[.。])\s*", item, maxsplit=1)[0]
            result[key] = values_only(item, source_key if source_key is not None else key, locale)
        return result
    if isinstance(value, list):
        return [values_only(item, source_key, locale) for item in value]
    if not isinstance(value, str):
        return value
    if source_key in STATIC_COPY_KEYS:
        translations = COPY[STATIC_COPY_KEYS[source_key]]
        return translations.get(locale, translations["en"])
    if source_key in MAC_ONLY_KEYS:
        return "Mac"
    if source_key in EXAMPLE_KEYS:
        # These are fixed examples, not user-supplied URLs or credentials.
        value = value.replace("hermes.example", "mac.example").replace("example.com/hermes", "example.com/mac")
    if source_key and "conduit_push plugin together" in source_key:
        # The Watch error keeps its translated text and any format argument.
        value = value.replace("conduit_push", "Mac")
    return value if is_identifier(value) else display(value, source_key, locale)


def display_aliases(values):
    # App Intents metadata needs LAA literals before the resource build phase.
    # Reuse each upstream translation for those fork-only keys, keeping the
    # original lookup keys and any explicit LAA translation.
    aliases = dict(values)
    for key, value in values.items():
        alias = display(key)
        if alias != key and not is_identifier(key):
            aliases.setdefault(alias, value)
    return aliases


def read_plist(path):
    try:
        with path.open("rb") as stream:
            return plistlib.load(stream)
    except (plistlib.InvalidFileException, ExpatError):
        # Catalyst's copyStrings can encode XML as UTF-16 while keeping its
        # UTF-8 declaration. Apple's parser normalizes that generated form.
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
        result[key] = display(text, english, locale)
    return result


def brand_info(info, kind, source, name=None, bundle_name=None):
    if name is not None:
        validate_name(name)
    if bundle_name is not None:
        validate_bundle_name(bundle_name)
    elif kind != "app":
        bundle_name = bundle_names[kind]
    info["CFBundleDisplayName"] = name if name is not None else names[kind]
    if bundle_name is not None:
        info["CFBundleName"] = bundle_name
    if kind in ("app", "watch"):
        catalog_path = source / ("Conduit/InfoPlist.xcstrings" if kind == "app" else "ConduitWatch/InfoPlist.xcstrings")
        catalog = json.loads(catalog_path.read_text())
        info.update(permission_strings(catalog, "en"))
    return info, bundle_name


def brand_bundle(bundle, kind, source, name=None, bundle_name=None):
    is_mac = (bundle / "Contents/Info.plist").is_file()
    info_path = bundle / ("Contents/Info.plist" if is_mac else "Info.plist")
    resources = bundle / "Contents/Resources" if is_mac else bundle
    info, bundle_name = brand_info(read_plist(info_path), kind, source, name, bundle_name)
    if is_mac and kind == "app":
        # Catalyst keeps the phone scene configuration, but cannot host CarPlay.
        configurations = info.get("UIApplicationSceneManifest", {}).get("UISceneConfigurations", {})
        configurations.pop("CPTemplateApplicationSceneSessionRoleApplication", None)
    if kind in ("app", "watch"):
        catalog_path = source / ("Conduit/InfoPlist.xcstrings" if kind == "app" else "ConduitWatch/InfoPlist.xcstrings")
        catalog = json.loads(catalog_path.read_text())
        # Update the localizations the build already produced, and never
        # create one: a draft language strip-draft-localizations.py removed
        # would come back. English needs no lproj; the base Info.plist has it.
        for path in resources.glob("*.lproj/InfoPlist.strings"):
            strings = read_plist(path)
            strings.update(permission_strings(catalog, path.parent.stem))
            if "CFBundleDisplayName" in strings:
                strings["CFBundleDisplayName"] = info["CFBundleDisplayName"]
            if "CFBundleName" in strings and bundle_name is not None:
                strings["CFBundleName"] = bundle_name
            with path.open("wb") as stream:
                plistlib.dump(strings, stream, fmt=plistlib.FMT_BINARY)
    with info_path.open("wb") as stream:
        plistlib.dump(info, stream, fmt=plistlib.FMT_BINARY, sort_keys=False)
    for directory in resources.glob("*.lproj"):
        for pattern in ("*.strings", "*.stringsdict"):
            for path in directory.glob(pattern):
                if path.name == "InfoPlist.strings":
                    continue
                data = read_plist(path)
                with path.open("wb") as stream:
                    plistlib.dump(display_aliases(values_only(data, locale=directory.stem)), stream, fmt=plistlib.FMT_BINARY, sort_keys=False)

    # String catalogs omit untranslated source-language entries from en.lproj.
    # Without explicit English values, Foundation displays the original key.
    catalog_dir = source / ("ConduitWatch" if kind in ("watch", "watch-widget") else "Conduit")
    english_dir = resources / "en.lproj"
    english_dir.mkdir(parents=True, exist_ok=True)
    for catalog_path in catalog_dir.glob("*.xcstrings"):
        if catalog_path.stem == "InfoPlist":
            continue
        catalog = json.loads(catalog_path.read_text())["strings"]
        english_path = english_dir / (catalog_path.stem + ".strings")
        english = read_plist(english_path) if english_path.exists() else {}
        for key in catalog:
            if (re.search(r"Conduit|Hermes|Paseo|パセオ", key)
                    or key in STATIC_COPY_KEYS or key in MAC_ONLY_KEYS) and key not in english:
                english[key] = values_only({key: key})[key]
        with english_path.open("wb") as stream:
            plistlib.dump(display_aliases(english), stream, fmt=plistlib.FMT_BINARY, sort_keys=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--input-info", type=Path)
    parser.add_argument("--output-info", type=Path)
    parser.add_argument("--kind", required=True, choices=tuple(names))
    parser.add_argument("--source", required=True, type=Path)
    # The home-screen name: the personal build keeps its own identity beside
    # the LAA one, and an env override is honored instead of ignored.
    parser.add_argument("--name")
    parser.add_argument("--bundle-name")
    args = parser.parse_args()
    if args.bundle and not args.input_info and not args.output_info:
        brand_bundle(args.bundle, args.kind, args.source, name=args.name, bundle_name=args.bundle_name)
    elif not args.bundle and args.input_info and args.output_info:
        info, _ = brand_info(read_plist(args.input_info), args.kind, args.source, args.name, args.bundle_name)
        args.output_info.parent.mkdir(parents=True, exist_ok=True)
        with args.output_info.open("wb") as stream:
            plistlib.dump(info, stream, sort_keys=False)
    else:
        parser.error("supply --bundle or both --input-info and --output-info")


if __name__ == "__main__":
    main()
