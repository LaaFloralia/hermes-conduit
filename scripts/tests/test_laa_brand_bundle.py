import importlib.util
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("laa_brand_bundle", ROOT / "scripts/laa/brand-bundle.py")
brand = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(brand)
CHECK_SPEC = importlib.util.spec_from_file_location("laa_brand_check", ROOT / "scripts/laa/check-brand-bundle.py")
checker = importlib.util.module_from_spec(CHECK_SPEC)
CHECK_SPEC.loader.exec_module(checker)
LANGUAGES = {"en", "de", "es", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"}


class LAABrandBundleTests(unittest.TestCase):
    def test_prepared_info_is_branded_before_intent_metadata_is_generated(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "prepared/Info.plist"
            command = [sys.executable, str(ROOT / "scripts/laa/brand-bundle.py"),
                       "--input-info", str(ROOT / "Conduit/Info.plist"), "--output-info", str(output),
                       "--kind", "app", "--source", str(ROOT), "--name", "LAA", "--bundle-name", "LAA"]
            subprocess.run(command, check=True, capture_output=True)
            with output.open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundleDisplayName"], "LAA")
            self.assertEqual(info["CFBundleName"], "LAA")
            self.assertNotIn("Conduit", info["NSMicrophoneUsageDescription"])
            self.assertNotIn("Hermes", info["NSMicrophoneUsageDescription"])
            self.assertEqual(info["CFBundleIdentifier"], "$(PRODUCT_BUNDLE_IDENTIFIER)")

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
            self.assertTrue(all("Hermes" not in value for value in strings.values()), language)
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
            # The build's own copy of the catalog-backed permission strings.
            with (local / "InfoPlist.strings").open("wb") as stream:
                plistlib.dump({"NSMicrophoneUsageDescription": "Conduitはマイクを使います。"}, stream)
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
            self.assertFalse([key for key in source_keys if ("Conduit" in key or "Hermes" in key) and key not in english])
            self.assertTrue(all("Conduit" not in value and "Hermes" not in value for value in english.values()))
            for key, copy_name in brand.STATIC_COPY_KEYS.items():
                if key in source_keys:
                    self.assertIn(key, english)
                    self.assertEqual(english[key], brand.COPY[copy_name]["en"])
            for key in brand.MAC_ONLY_KEYS:
                if key in source_keys:
                    self.assertEqual(english[key], "Mac")
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

    def make_app_bundle(self, root):
        """A built app: the plist keys the brand must keep, and one lproj."""
        bundle = root / "Conduit.app"
        local = bundle / "ja.lproj"
        local.mkdir(parents=True)
        with (bundle / "Info.plist").open("wb") as stream:
            plistlib.dump({
                "CFBundleDisplayName": "Conduit",
                "CFBundleName": "Conduit",
                "CFBundleIcons": {"CFBundleAlternateIcons": {"Light": {"CFBundleIconFiles": ["icon-light-120"]}}},
                "ConduitLauncherAppGroup": "group.keep",
            }, stream)
        with (local / "Localizable.strings").open("wb") as stream:
            plistlib.dump({"Open Conduit": "Conduitを開く", "identifier": "conduit://keep"}, stream)
        with (local / "InfoPlist.strings").open("wb") as stream:
            plistlib.dump({"NSMicrophoneUsageDescription": "old",
                           "ConduitAnotherKey": "keep me"}, stream)
        return bundle

    def read_bundle(self, bundle):
        return {path.relative_to(bundle): path.read_bytes()
                for path in sorted(bundle.rglob("*")) if path.is_file()}

    def test_branding_the_same_bundle_twice_changes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = self.make_app_bundle(Path(tmp))
            brand.brand_bundle(bundle, "app", ROOT)
            first = self.read_bundle(bundle)
            brand.brand_bundle(bundle, "app", ROOT)
            self.assertEqual(self.read_bundle(bundle), first)

    def test_personal_build_keeps_its_own_name_and_icon_registration(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = self.make_app_bundle(Path(tmp))
            brand.brand_bundle(bundle, "app", ROOT, name="LAA Personal", bundle_name="LAA Personal")
            with (bundle / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundleDisplayName"], "LAA Personal")
            self.assertEqual(info["CFBundleName"], "LAA Personal")
            # The alternate (Light) icon stays registered, as upstream had it.
            self.assertIn("Light", info["CFBundleIcons"]["CFBundleAlternateIcons"])
            self.assertEqual(info["ConduitLauncherAppGroup"], "group.keep")

    def test_personal_build_selects_the_laa_home_icon(self):
        spec = (ROOT / "project-personal.yml").read_text()
        self.assertRegex(spec, r"(?m)^\s*ASSETCATALOG_COMPILER_APPICON_NAME:\s*AppIcon-LAA\s*$")

    def test_laa_app_sets_its_bundle_name_and_keeps_other_localized_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = self.make_app_bundle(Path(tmp))
            brand.brand_bundle(bundle, "app", ROOT, name="LAA", bundle_name="LAA")
            with (bundle / "Info.plist").open("rb") as stream:
                self.assertEqual(plistlib.load(stream)["CFBundleName"], "LAA")
            with (bundle / "ja.lproj/InfoPlist.strings").open("rb") as stream:
                strings = plistlib.load(stream)
            self.assertNotIn("Conduit", strings["NSMicrophoneUsageDescription"])
            self.assertEqual(strings["ConduitAnotherKey"], "keep me")

    def test_watch_bundle_is_branded_with_its_own_permission_catalog(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "ConduitWatch.app"
            (bundle / "ja.lproj").mkdir(parents=True)
            with (bundle / "ja.lproj/InfoPlist.strings").open("wb") as stream:
                plistlib.dump({"NSMicrophoneUsageDescription": "Conduitはマイクを使います。"}, stream)
            with (bundle / "Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleDisplayName": "Conduit"}, stream)
            brand.brand_bundle(bundle, "watch", ROOT)
            with (bundle / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundleDisplayName"], "LAA")
            self.assertNotIn("Conduit", info["NSMicrophoneUsageDescription"])
            with (bundle / "ja.lproj/InfoPlist.strings").open("rb") as stream:
                self.assertNotIn("Conduit", plistlib.load(stream)["NSMicrophoneUsageDescription"])

    def test_identifier_like_values_keep_their_spelling(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = self.make_app_bundle(Path(tmp))
            with (bundle / "ja.lproj/Localizable.strings").open("wb") as stream:
                plistlib.dump({"identifier": "conduit://keep",
                               "group": "group.com.milim.relay.launcher",
                               "address": "ops@conduit.example",
                               "symbol": "ConduitAppGroup",
                               "sentence": "Conduitを開く"}, stream)
            brand.brand_bundle(bundle, "app", ROOT)
            with (bundle / "ja.lproj/Localizable.strings").open("rb") as stream:
                localized = plistlib.load(stream)
            self.assertEqual(localized["identifier"], "conduit://keep")
            self.assertEqual(localized["group"], "group.com.milim.relay.launcher")
            self.assertEqual(localized["address"], "ops@conduit.example")
            self.assertEqual(localized["symbol"], "ConduitAppGroup")
            self.assertEqual(localized["sentence"], "LAAを開く")

    def test_punctuation_does_not_hide_display_names(self):
        for value in ("Conduit.", "Conduit:", "Conduit/LAA", "Conduit.LAA"):
            with self.subTest(value=value):
                self.assertIn("LAA", brand.values_only({"copy": value})["copy"])
                self.assertNotIn("Conduit", brand.values_only({"copy": value})["copy"])

    def test_invalid_name_does_not_modify_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = self.make_app_bundle(Path(tmp))
            before = self.read_bundle(bundle)
            for name in ("", "  ", "LAA/Other", " LAA", "LAA\n", "LAA\x00", "Conduit LAA", "Hermes"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    brand.brand_bundle(bundle, "app", ROOT, name=name)
                self.assertEqual(self.read_bundle(bundle), before)
            for name in ("", "LAA/Other", "LAA\n", "x" * 17, "日本語", "conduit", "HERMES"):
                with self.subTest(bundle_name=name), self.assertRaises(ValueError):
                    brand.brand_bundle(bundle, "app", ROOT, bundle_name=name)
                self.assertEqual(self.read_bundle(bundle), before)

    def test_agent_and_connection_copy_keeps_format_arguments(self):
        self.assertEqual(brand.display("Connect to Hermes server %@", "Connect to Hermes server %@"), "Connect to Mac %@")
        self.assertEqual(brand.display("Hermes replied to %@", "Hermes replied to %@"), "Ciel replied to %@")
        self.assertEqual(brand.display("Hermesサーバーが応答しました", "Hermes server replied"), "Macが応答しました")

    def test_all_catalog_translations_keep_format_arguments(self):
        for file in ("Conduit/Localizable.xcstrings", "ConduitWatch/Localizable.xcstrings"):
            catalog = json.loads((ROOT / file).read_text())["strings"]
            for key, entry in catalog.items():
                for language, local in entry.get("localizations", {}).items():
                    value = local.get("stringUnit", {}).get("value")
                    if not value or ("Hermes" not in value and "Conduit" not in value):
                        continue
                    result = brand.values_only({key: value})[key]
                    with self.subTest(file=file, key=key, language=language):
                        self.assertNotIn("Hermes", result)
                        self.assertNotIn("Conduit", result)
                        # The privacy copy deliberately drops an unrelated
                        # developer claim; the data destination stays intact.
                        if "Conduit's developer can't see it." not in key:
                            self.assertEqual(re.findall(r"%(?:\d+\$)?[@dfsi]", value),
                                             re.findall(r"%(?:\d+\$)?[@dfsi]", result))

    def test_static_replacements_are_localized_and_do_not_change_keys(self):
        catalogs = [json.loads((ROOT / path).read_text())["strings"] for path in
                    ("Conduit/Localizable.xcstrings", "ConduitWatch/Localizable.xcstrings")]
        for source, copy_name in brand.STATIC_COPY_KEYS.items():
            self.assertTrue(any(source in catalog for catalog in catalogs), source)
            self.assertNotRegex(source, r"%(?:\d+\$)?[@dfsi]")
            self.assertEqual(set(brand.COPY[copy_name]), LANGUAGES)
            for language in LANGUAGES:
                result = brand.values_only({source: source}, locale=language)
                self.assertEqual(list(result), [source])
                self.assertEqual(result[source], brand.COPY[copy_name][language])
                self.assertNotRegex(result[source], re.compile(r"Conduit|Hermes", re.I))

    def test_open_source_notices_preserve_the_original_mit_texts(self):
        notice = (ROOT / "assets/laa/LAAOpenSourceNotices.txt").read_text()
        self.assertIn((ROOT / "LICENSE").read_text().strip(), notice)
        metal = (ROOT / "Conduit/Views/LiquidOrb/LiquidOrb.metal").read_text().splitlines()
        start = metal.index("// MIT License")
        end = metal.index("// SOFTWARE.", start) + 1
        shader_license = "\n".join(line[3:] if line.startswith("// ") else "" for line in metal[start:end])
        self.assertIn(shader_license, notice)

    def test_only_fixed_examples_and_watch_messages_are_rewritten(self):
        example = next(key for key in brand.EXAMPLE_KEYS if "hermes.example.com" in key)
        rewritten = brand.values_only({example: example})[example]
        self.assertIn("https://mac.example.com", rewritten)
        self.assertIn("https://example.com/mac", rewritten)
        self.assertEqual(brand.values_only({"user-url": "https://hermes.example"})["user-url"],
                         "https://hermes.example")
        watch = "Hermes started %@, not Grok. Update Conduit and the conduit_push plugin together."
        result = brand.values_only({watch: watch})[watch]
        self.assertIn("%@", result)
        self.assertNotRegex(result, re.compile(r"Conduit|Hermes", re.I))

    def test_all_catalog_display_values_pass_the_artifact_inspector(self):
        for path in ("Conduit/Localizable.xcstrings", "ConduitWatch/Localizable.xcstrings",
                     "Conduit/AppShortcuts.xcstrings"):
            catalog = json.loads((ROOT / path).read_text())["strings"]
            issues = []
            for key, entry in catalog.items():
                samples = {"en": key}
                for language, translation in entry.get("localizations", {}).items():
                    unit = translation.get("stringUnit", {})
                    if "value" in unit:
                        samples[language] = unit["value"]
                for language, value in samples.items():
                    localized = brand.values_only({key: value}, locale=language)
                    checker.scan_values(localized, f"{path}/{language}", issues)
            self.assertEqual(issues, [], "\n".join(issues[:20]))
