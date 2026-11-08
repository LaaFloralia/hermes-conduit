import importlib.util
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("laa_brand_check", ROOT / "scripts/laa/check-brand-bundle.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        plistlib.dump(value, stream, fmt=plistlib.FMT_BINARY)


class LAABrandCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Conduit.app"
        self.parts = {
            checker.APP_ID: self.app,
            checker.APP_ID + ".widgets": self.app / "PlugIns/Widgets.appex",
            checker.APP_ID + ".ShareExtension": self.app / "PlugIns/Share.appex",
            checker.APP_ID + ".NotificationService": self.app / "PlugIns/Notification.appex",
            checker.APP_ID + ".watchkitapp": self.app / "Watch/Watch.app",
            checker.APP_ID + ".watchkitapp.widgets": self.app / "Watch/Watch.app/PlugIns/Widgets.appex",
        }
        for identifier, part in self.parts.items():
            write_plist(part / "Info.plist", {"CFBundleIdentifier": identifier,
                        "CFBundleName": "LAA", "CFBundleDisplayName": "LAA",
                        "CFBundleExecutable": "Conduit", "CFBundleURLSchemes": ["conduit"]})
            write_plist(part / "en.lproj/Localizable.strings", {
                "Open Conduit": "Open LAA", "link": "conduit://widget"})
            if identifier in checker.INTENTS:
                write_plist(part / "Metadata.appintents/extract.actionsdata", {
                    "typeName": "ConduitProfileEntity", "title": "Talk to LAA"})
        shutil.copyfile(checker.NOTICE_SOURCE, self.app / checker.NOTICE_NAME)

    def test_complete_bundle_passes_and_preserves_internal_identifiers(self):
        self.assertEqual(checker.check_bundle(self.app), [])

    def test_utf16_xml_plurals_are_checked_and_malformed_xml_is_rejected(self):
        resource = self.app / "en.lproj/Localizable.stringsdict"
        for display, should_fail in (("%lld LAA items", False), ("%lld Conduit items", True)):
            with self.subTest(display=display):
                resource.write_bytes(plistlib.dumps({"items": {"other": display}})
                                     .decode("utf-8").encode("utf-16"))
                self.assertEqual(bool(checker.check_bundle(self.app)), should_fail)
        resource.write_bytes(b'<?xml version="1.0"?><plist><dict>')
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(self.app)

    def test_catalyst_checks_nested_resources_and_requires_its_extension(self):
        mac = Path(self.temp.name) / "Mac.app"
        extension = mac / "Contents/PlugIns/Notification.appex"
        for identifier, part in ((checker.APP_ID, mac), (checker.APP_ID + ".NotificationService", extension)):
            write_plist(part / "Contents/Info.plist", {"CFBundleIdentifier": identifier,
                        "CFBundleName": "LAA", "CFBundleDisplayName": "LAA"})
            write_plist(part / "Contents/Resources/en.lproj/Localizable.strings", {"Open Conduit": "Open LAA"})
        write_plist(mac / "Contents/Resources/Metadata.appintents/extract.actionsdata", {"title": "Open LAA"})
        shutil.copyfile(checker.NOTICE_SOURCE, mac / "Contents/Resources" / checker.NOTICE_NAME)
        self.assertEqual(checker.check_bundle(mac), [])
        write_plist(extension / "Contents/Resources/en.lproj/Localizable.strings", {"title": "Open Conduit"})
        self.assertTrue(checker.check_bundle(mac))
        shutil.rmtree(extension)
        with self.assertRaisesRegex(checker.CheckError, "missing required bundles"):
            checker.check_bundle(mac)

    def test_internal_link_inside_a_sentence_does_not_hide_visible_brand(self):
        resource = self.app / "en.lproj/Localizable.strings"
        write_plist(resource, {"prompt": "Use conduit://connect?url=ADDRESS&username=USERNAME."})
        self.assertEqual(checker.check_bundle(self.app), [])
        write_plist(resource, {"prompt": "Open Conduit and use conduit://connect?url=ADDRESS."})
        self.assertTrue(checker.check_bundle(self.app))
        write_plist(resource, {"link": "https://conduit.example"})
        self.assertTrue(checker.check_bundle(self.app))
        write_plist(resource, {"address": "support@conduit.example"})
        self.assertTrue(checker.check_bundle(self.app))
        write_plist(resource, {"label": "https://は不要です。Conduitに接続します。"})
        self.assertTrue(checker.check_bundle(self.app))

    def test_old_display_string_in_every_component_fails(self):
        for identifier, part in self.parts.items():
            with self.subTest(component=identifier):
                resource = part / "ja.lproj/Localizable.strings"
                write_plist(resource, {"display": "Conduitを開く"})
                self.assertTrue(checker.check_bundle(self.app))
                resource.unlink()

    def test_permission_plurals_and_intent_metadata_are_checked(self):
        app_info = self.app / "Info.plist"
        info = checker.load_resource(app_info)
        info["NSMicrophoneUsageDescription"] = "Hermes needs the microphone"
        write_plist(app_info, info)
        self.assertTrue(checker.check_bundle(self.app))
        del info["NSMicrophoneUsageDescription"]
        write_plist(app_info, info)
        plural = self.app / "en.lproj/Localizable.stringsdict"
        write_plist(plural, {"items": {"one": "Conduit item"}})
        self.assertTrue(checker.check_bundle(self.app))
        plural.unlink()
        actions = self.app / "Metadata.appintents/extract.actionsdata"
        write_plist(actions, {"typeName": "ConduitProfileEntity", "title": "Talk to Hermes"})
        self.assertTrue(checker.check_bundle(self.app))

    def test_generated_shortcut_yaml_checks_titles_and_utterances(self):
        yaml = self.app / "Metadata.appintents/root.ssu.yaml"
        safe = ("apiVersion: ssu/v1\nnlu:\n  shortcuts:\n    intents:\n"
                "    - metadata:\n        name: SendToHermesIntent_1\n        title: Talk to Monet\n"
                "      corpuses:\n        training:\n        - locale: en\n          utterances:\n"
                "          - Talk to ${ConduitProfileEntity} in ${+applicationName}\n"
                "- name: ConduitProfileEntity\n")
        yaml.write_text(safe)
        self.assertEqual(checker.check_bundle(self.app), [])
        yaml.write_text(safe.replace("title: Talk to Monet", "title: Talk to Hermes"))
        self.assertTrue(checker.check_bundle(self.app))
        yaml.write_text(safe.replace("Talk to ${ConduitProfileEntity}", "Talk to Conduit"))
        self.assertTrue(checker.check_bundle(self.app))
        yaml.write_text(safe.replace("title: Talk to Monet", "title: ${ConduitProfileEntity}"))
        self.assertTrue(checker.check_bundle(self.app))
        yaml.write_text(safe + 'title: "C\\u006fnduit"\n')
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(self.app)

    def test_metadata_identifier_exceptions_do_not_hide_display_copy(self):
        actions = self.app / "Metadata.appintents/extract.actionsdata"
        write_plist(actions, {"fullyQualifiedTypeName": "Conduit.SomeIntent",
                              "actionIdentifier": "SendToHermesIntent"})
        self.assertEqual(checker.check_bundle(self.app), [])
        write_plist(actions, {"actionIdentifier": "Open Hermes", "title": "Open Monet"})
        self.assertTrue(checker.check_bundle(self.app))
        write_plist(actions, {"fullyQualifiedTypeName": "Conduit.SomeIntent", "title": "Open Hermes"})
        self.assertTrue(checker.check_bundle(self.app))

    def test_missing_and_unreadable_resources_fail_closed(self):
        local = self.parts[checker.APP_ID + ".widgets"] / "en.lproj/Localizable.strings"
        local.unlink()
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(self.app)
        local.write_bytes(b"invalid resource")
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(self.app)
        write_plist(local, {"key": "LAA"})
        metadata = self.app / "Metadata.appintents/extract.actionsdata"
        metadata.write_bytes(b"unknown metadata format")
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(self.app)

    def test_open_source_notices_must_be_present_and_complete(self):
        notice = self.app / checker.NOTICE_NAME
        notice.unlink()
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(self.app)
        notice.write_text("MIT License")
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(self.app)

    def test_wrong_or_missing_bundle_fails_closed(self):
        missing = self.parts[checker.APP_ID + ".ShareExtension"] / "Info.plist"
        missing.unlink()
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(self.app)
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(Path(self.temp.name))

    def test_additional_extension_cannot_bypass_inspection(self):
        extension = self.app / "PlugIns/Future.appex"
        write_plist(extension / "Info.plist", {
            "CFBundleIdentifier": checker.APP_ID + ".future",
            "CFBundleName": "LAA", "CFBundleDisplayName": "LAA"})
        write_plist(extension / "en.lproj/Localizable.strings", {"title": "Open Hermes"})
        self.assertTrue(checker.check_bundle(self.app))
        write_plist(extension / "en.lproj/Localizable.strings", {"title": "Open Monet"})
        self.assertEqual(checker.check_bundle(self.app), [])
        (extension / "Info.plist").unlink()
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(self.app)

    def test_testflight_checks_archive_before_export(self):
        script = (ROOT / "scripts/laa/testflight.sh").read_text()
        self.assertLess(script.index('xcodebuild archive'), script.index('check-brand-bundle.py'))
        self.assertLess(script.index('check-brand-bundle.py'), script.index('xcodebuild -exportArchive'))
        self.assertIn('|| fail "LAA branding inspection failed', script)

    def test_brand_phases_wait_for_the_processed_info_plist(self):
        for spec, names in (("project-laa.yml", ("app", "watch", "watch widget", "notification", "widget", "share")),
                            ("project-personal.yml", ("personal",))):
            text = (ROOT / spec).read_text()
            for name in names:
                label = f"Brand LAA {name} resources" if name != "personal" else "Brand resources for the personal build"
                with self.subTest(spec=spec, phase=label):
                    phase = text.split(f"- name: {label}\n", 1)[1].split("script: |", 1)[0]
                    self.assertIn('inputFiles: ["$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"]', phase)


if __name__ == "__main__":
    unittest.main()
