import importlib.util
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("laa_brand_bundle", ROOT / "scripts/laa/brand-bundle.py")
brand = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(brand)
CHECK_SPEC = importlib.util.spec_from_file_location("laa_brand_check", ROOT / "scripts/laa/check-brand-bundle.py")
checker = importlib.util.module_from_spec(CHECK_SPEC)
CHECK_SPEC.loader.exec_module(checker)
LANGUAGES = {"en", "de", "es", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"}


class LAABrandBundleTests(unittest.TestCase):
    def test_catalyst_utf16_plurals_keep_keys_and_format_specifiers(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "Notification.appex"
            local = bundle / "Contents/Resources/en.lproj"
            local.mkdir(parents=True)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleName": "Conduit"}))
            plural = local / "Localizable.stringsdict"
            original = {"%lld Conduit items": {
                "NSStringLocalizedFormatKey": "%#@items@",
                "items": {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                          "NSStringFormatValueTypeKey": "lld", "one": "%lld Conduit item",
                          "other": "%lld Conduit items"}}}
            # Match Xcode's UTF-16 copyStrings output with its UTF-8 XML declaration.
            plural.write_bytes(plistlib.dumps(original).decode("utf-8").encode("utf-16"))
            brand.brand_bundle(bundle, "notification", ROOT)
            result = plistlib.loads(plural.read_bytes())
            self.assertEqual(result, brand.display_aliases(brand.values_only(original, locale="en")))
            self.assertEqual(result["%lld Conduit items"]["NSStringLocalizedFormatKey"], "%#@items@")
            self.assertEqual(result["%lld Conduit items"]["items"]["other"], "%lld LAA items")

    def test_catalyst_brands_contents_resources_and_preserves_phone_scene(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp) / "Conduit.app"
            local = bundle / "Contents/Resources/ja.lproj"
            local.mkdir(parents=True)
            info_path = bundle / "Contents/Info.plist"
            info_path.write_bytes(plistlib.dumps({
                "CFBundleName": "Conduit", "CFBundleExecutable": "Conduit",
                "UIApplicationSceneManifest": {"UISceneConfigurations": {
                    "CPTemplateApplicationSceneSessionRoleApplication": [{"UISceneClassName": "CarPlayScene"}],
                    "UIWindowSceneSessionRoleApplication": [{"UISceneClassName": "MainScene"}]}}
            }))
            (local / "Localizable.strings").write_bytes(plistlib.dumps({"Open Conduit": "Conduitを開く"}))
            (local / "InfoPlist.strings").write_bytes(plistlib.dumps({"CFBundleName": "Conduit"}))
            brand.brand_bundle(bundle, "app", ROOT, bundle_name="LAA")
            info = plistlib.loads(info_path.read_bytes())
            self.assertEqual(info["CFBundleName"], "LAA")
            self.assertEqual(info["CFBundleDisplayName"], "LAA")
            self.assertEqual(info["CFBundleExecutable"], "Conduit")
            self.assertNotIn("Conduit", info["NSMicrophoneUsageDescription"])
            scenes = info["UIApplicationSceneManifest"]["UISceneConfigurations"]
            self.assertEqual(scenes, {"UIWindowSceneSessionRoleApplication": [{"UISceneClassName": "MainScene"}]})
            self.assertEqual(plistlib.loads((local / "Localizable.strings").read_bytes())["Open Conduit"], "LAAを開く")
            self.assertEqual(plistlib.loads((local / "InfoPlist.strings").read_bytes())["CFBundleName"], "LAA")
            self.assertTrue((bundle / "Contents/Resources/en.lproj/Localizable.strings").is_file())
            self.assertFalse((bundle / "en.lproj").exists())

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
            self.assertNotIn("LAADotsCallURL", info)

    def test_dots_call_link_comes_only_from_the_release_environment(self):
        link = "https://chatgpt.com/dots/00000000-0000-4000-8000-000000000000~0123abcd"
        self.assertEqual(brand.dots_call({}, "app", link), {"LAADotsCallURL": link})
        self.assertEqual(brand.dots_call({"LAADotsCallURL": link}, "app", None), {})
        self.assertEqual(brand.dots_call({}, "widgets", link), {})
        with self.assertRaises(ValueError):
            brand.dots_call({}, "app", "https://example.com/dots/x")

    def test_prepared_info_carries_the_dots_link_without_printing_it(self):
        link = "https://chatgpt.com/dots/00000000-0000-4000-8000-000000000000~0123abcd"
        command = [sys.executable, str(ROOT / "scripts/laa/brand-bundle.py"),
                   "--input-info", str(ROOT / "Conduit/Info.plist"), "--output-info", "",
                   "--kind", "app", "--source", str(ROOT), "--name", "LAA", "--bundle-name", "LAA"]

        def prepare(path, value):
            command[command.index("--output-info") + 1] = str(path)
            return subprocess.run(command, capture_output=True, text=True,
                                  env={**os.environ, checker.DOTS_CALL_ENV: value})

        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "prepared/Info.plist"
            prepare(output, link)
            self.assertEqual(plistlib.loads(output.read_bytes())["LAADotsCallURL"], link)
            bad = prepare(output, "https://example.com/dots/x")
            self.assertNotEqual(bad.returncode, 0)
            self.assertNotIn("https://example.com/dots/x", bad.stdout + bad.stderr)
            prepare(output, "")
            self.assertNotIn("LAADotsCallURL", plistlib.loads(output.read_bytes()))

    def test_a_release_with_the_dots_link_checks_the_app_info(self):
        link = "https://chatgpt.com/dots/00000000-0000-4000-8000-000000000000~0123abcd"
        checker.check_dots_call({}, None)
        with self.assertRaises(checker.CheckError) as missing:
            checker.check_dots_call({}, link)
        self.assertNotIn(link, str(missing.exception))
        checker.check_dots_call({checker.DOTS_CALL_KEY: link}, link)
        with self.assertRaises(checker.CheckError):
            checker.check_dots_call({checker.DOTS_CALL_KEY: ""}, link)
        with mock.patch.dict(os.environ, {checker.DOTS_CALL_ENV: link}):
            with self.assertRaises(checker.CheckError):
                checker.check_dots_call({})
            checker.check_dots_call({checker.DOTS_CALL_KEY: link})
        # The archive check itself runs it, not only this test.
        self.assertIn("check_dots_call(root_info)",
                      (ROOT / "scripts/laa/check-brand-bundle.py").read_text())

    def test_testflight_hands_the_dots_link_only_to_the_brand_step(self):
        script = (ROOT / "scripts/laa/testflight.sh").read_text()
        export = 'export LAA_DOTS_CALL_URL="$dots_call"'
        self.assertIn('dots_call="${LAA_DOTS_CALL_URL:-}"', script)
        self.assertLess(script.index('dots_call="${LAA_DOTS_CALL_URL:-}"'), script.index(export))
        self.assertLess(script.index(export), script.index("xcodebuild archive"))
        self.assertLess(script.index(export), script.index("check-brand-bundle.py"))
        for line in script.splitlines():
            if "LAA_DOTS_CALL_URL" in line or "$dots_call" in line:
                self.assertNotRegex(line, r"echo|printf|tee|log")

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
        self.assertRegex(spec, r"(?m)^\s*EXCLUDED_SOURCE_FILE_NAMES:\s*Info.plist\s*$")

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
        self.assertEqual(brand.display("Connect to Hermes server %@", "Connect to Hermes server %@"), "Connect to LAA server %@")
        self.assertEqual(brand.display("Hermes replied to %@", "Hermes replied to %@"), "LAA replied to %@")
        self.assertEqual(brand.display("Hermesサーバーが応答しました", "Hermes server replied"), "LAAサーバーが応答しました")

    def test_english_copy_can_name_the_agent_and_mac_in_the_same_sentence(self):
        source = "Hermes replies. The Hermes notifier plugin runs on your Hermes server."
        self.assertEqual(brand.values_only({source: source})[source],
                         "LAA replies. The LAA plugin runs on your LAA server.")
        source = "Your Hermes server doesn't offer voice. Update Hermes to use Voice."
        self.assertEqual(brand.values_only({source: source})[source],
                         "Your LAA server doesn't offer voice. Update LAA to use Voice.")

    def test_owner_facing_names_in_english_and_japanese(self):
        samples = {
            "Talk to Hermes": "Talk to LAA",
            "Hermes wants to talk": "LAA wants to talk",
            "Calls from Hermes": "Calls from LAA",
            "Ask Hermes": "Ask LAA",
            "Conduit plugin": "LAA plugin",
            "Conduitプラグインを更新": "LAAの連携プラグインを更新",
            "Hermesのプロファイル": "AI社員",
            "Paseoの状態を確認してください。": "Workの状態を確認してください。",
        }
        for original, expected in samples.items():
            with self.subTest(original=original):
                self.assertEqual(brand.display(original), expected)
        self.assertEqual(brand.display("Monet"), "Monet")
        self.assertEqual(brand.display("Ask Ciel"), "Ask Monet")
        self.assertEqual(brand.display("Cielに聞く"), "Monetに聞く")

    def test_japanese_copy_closes_the_space_after_laa(self):
        samples = {
            "Hermes が作業中です。": "LAAが作業中です。",
            "通知がオンなら、Conduit が自動でオンにします。": "通知がオンなら、LAAが自動でオンにします。",
            "LAA の設定です。": "LAAの設定です。",
        }
        for original, expected in samples.items():
            with self.subTest(original=original):
                self.assertEqual(brand.values_only({"copy": original}, locale="ja")["copy"], expected)
        # English keeps the words apart: only Japanese copy joins them.
        self.assertEqual(brand.values_only({"copy": "LAA is here"}, locale="en")["copy"], "LAA is here")

    def test_japanese_copy_uses_the_owners_words(self):
        samples = {
            "https://は入力不要です。次に、このダッシュボードのサインイン方法をConduitが確認します。":
                "https://は入力不要です。次に、このMacへのサインイン方法をLAAが確認します。",
            "このホストのほかのプロファイルとも共有": "このMacのほかのAI社員とも共有",
            "新しいダッシュボード": "新しいMac",
            "プロファイルID：%@": "AI社員ID：%@",
            "他者がHermesをホストしている場合は、そのホストも読み取れます。":
                "他者がLAAを運用している場合は、その提供元も読み取れます。",
            "実際のブラウザプロファイルを使う": "実際のブラウザ設定を使う",
        }
        for original, expected in samples.items():
            with self.subTest(original=original):
                self.assertEqual(brand.values_only({"copy": original}, locale="ja")["copy"], expected)
        # A hostname and a cookie scope are technical terms, not the owner's Mac.
        for technical in ("Tailscaleのホスト名", "ホストスコープのセッションCookie"):
            with self.subTest(technical=technical):
                self.assertIn("ホスト", brand.display(technical, None, "ja"))

    def test_intent_aliases_reuse_japanese_translation_without_changing_lookup_keys(self):
        original = {"Tell Hermes": "Hermesに伝える", "LAA profile": "LAAプロファイル"}
        values = brand.display_aliases(brand.values_only(original, locale="ja"))
        self.assertEqual(values["Tell LAA"], "LAAに伝える")
        self.assertEqual(values["Tell Hermes"], "LAAに伝える")
        self.assertEqual(values["AI employee"], "AI社員")
        renamed = brand.display_aliases(brand.values_only({"Talk to Ciel": "Cielと話す"}, locale="ja"))
        self.assertEqual(renamed["Talk to Ciel"], "Monetと話す")
        self.assertEqual(renamed["Talk to Monet"], "Monetと話す")
        self.assertEqual(brand.display_aliases(values), values)
        explicit = {"Talk to Hermes": "LAA と話す", "Talk to LAA": "LAAと話す"}
        self.assertEqual(brand.display_aliases(explicit)["Talk to LAA"], "LAAと話す")

    def test_english_fallback_also_brands_shortcut_catalogs(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = self.make_app_bundle(Path(tmp))
            brand.brand_bundle(bundle, "app", ROOT)
            values = plistlib.loads((bundle / "en.lproj/AppShortcuts.strings").read_bytes())
            self.assertEqual(values["Ask Hermes"], "Ask LAA")
            self.assertEqual(values["Ask ${applicationName}"], "Ask ${applicationName}")
            self.assertEqual(values["Send to ${applicationName}"], "Send to ${applicationName}")
            self.assertEqual(values["Talk to Conduit"], "Talk to LAA")
            self.assertTrue(all("Hermes" not in value and "Conduit" not in value
                                for value in values.values()))

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

    def test_japanese_operations_keep_lookup_keys_and_other_languages(self):
        source = {"Cancel": "Cancel", "Message": "Message", "Chat": "Chat", "user-content": "Cancel"}
        result = brand.values_only(source, locale="ja")
        self.assertEqual(set(result), set(source))
        self.assertEqual(result["Cancel"], "キャンセル")
        self.assertEqual(result["Message"], "メッセージ")
        self.assertEqual(result["Chat"], "チャット")
        self.assertEqual(result["user-content"], "Cancel")
        self.assertEqual(brand.values_only(source, locale="en"), source)

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
