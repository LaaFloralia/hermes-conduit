import importlib.util
import json
import plistlib
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("laa_brand_bundle", ROOT / "scripts/laa/brand-bundle.py")
brand = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(brand)


class LAABrandBundleTests(unittest.TestCase):
    def test_localized_privacy_copy_does_not_transfer_developer_claim(self):
        strings = json.loads((ROOT / "Conduit/Localizable.xcstrings").read_text())["strings"]
        keys = [key for key in strings if "Conduit's developer can't see it." in key]
        self.assertEqual(len(keys), 3)
        for key in keys:
            examples = [key] + [entry["stringUnit"]["value"]
                                for entry in strings[key]["localizations"].values()]
            for text in examples:
                branded = brand.values_only({key: text})[key]
                self.assertNotIn("Conduit", branded)
                self.assertEqual(len(re.findall(r"%(?:\d+\$)?@", branded)), 2)
                self.assertEqual(len(re.findall(r"[.。]", branded)), 1)

    def test_permission_text_preserves_each_language_without_upstream_developer_claim(self):
        catalog = json.loads((ROOT / "Conduit/InfoPlist.xcstrings").read_text())
        languages = next(iter(catalog["strings"].values()))["localizations"]
        for language in languages:
            strings = brand.permission_strings(catalog, language)
            self.assertEqual(len(strings), 15)
            self.assertTrue(all("Conduit" not in value for value in strings.values()), language)
            self.assertTrue(all("Hermes" in strings[key] for key in (
                "NSCalendarsFullAccessUsageDescription", "NSHealthShareUsageDescription")), language)
        self.assertIn("マイク", brand.permission_strings(catalog, "ja")["NSMicrophoneUsageDescription"])
        self.assertNotIn("開発者", brand.permission_strings(catalog, "ja")["NSHealthShareUsageDescription"])
        self.assertNotIn("developer", brand.permission_strings(catalog, "en")["NSHealthShareUsageDescription"])

    def test_generated_bundle_changes_values_and_names_without_changing_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "Conduit.app"
            local = bundle / "ja.lproj"
            local.mkdir(parents=True)
            with (bundle / "Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleDisplayName": "Conduit", "ConduitLauncherAppGroup": "group.keep"}, stream)
            with (local / "Localizable.strings").open("wb") as stream:
                plistlib.dump({"Open Conduit": "Conduitを開く", "identifier": "conduit://keep"}, stream)
            brand.brand_bundle(bundle, "app", ROOT)
            with (bundle / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundleDisplayName"], "LAA")
            self.assertEqual(info["ConduitLauncherAppGroup"], "group.keep")
            with (local / "Localizable.strings").open("rb") as stream:
                localized = plistlib.load(stream)
            self.assertEqual(localized["Open Conduit"], "LAAを開く")
            self.assertEqual(localized["identifier"], "conduit://keep")
            with (local / "InfoPlist.strings").open("rb") as stream:
                self.assertNotIn("Conduit", plistlib.load(stream)["NSMicrophoneUsageDescription"])
            with (bundle / "en.lproj/Localizable.strings").open("rb") as stream:
                english = plistlib.load(stream)
            self.assertEqual(english["Open Conduit"], "Open LAA")
            source_keys = json.loads((ROOT / "Conduit/Localizable.xcstrings").read_text())["strings"]
            self.assertFalse([key for key in source_keys if "Conduit" in key and key not in english])
            self.assertTrue(all("Conduit" not in value for value in english.values()))
            health = next(value for key, value in english.items()
                          if "Conduit's developer can't see it." in key)
            self.assertNotIn("developer", health)
            self.assertEqual(len(re.findall(r"%(?:\d+\$)?@", health)), 2)

    def test_extension_names(self):
        for kind, name in (("watch-widget", "LAA Watch Widgets"), ("widgets", "LAA Widgets"),
                           ("notification", "LAA Notifications"), ("share", "LAA")):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                bundle = Path(tmp)
                with (bundle / "Info.plist").open("wb") as stream:
                    plistlib.dump({}, stream)
                brand.brand_bundle(bundle, kind, ROOT)
                with (bundle / "Info.plist").open("rb") as stream:
                    self.assertEqual(plistlib.load(stream)["CFBundleDisplayName"], name)
