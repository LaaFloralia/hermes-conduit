import importlib.util
import plistlib
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

    def test_complete_bundle_passes_and_preserves_internal_identifiers(self):
        self.assertEqual(checker.check_bundle(self.app), [])

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

    def test_wrong_or_missing_bundle_fails_closed(self):
        missing = self.parts[checker.APP_ID + ".ShareExtension"] / "Info.plist"
        missing.unlink()
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(self.app)
        with self.assertRaises(checker.CheckError):
            checker.check_bundle(Path(self.temp.name))

    def test_testflight_checks_archive_before_export(self):
        script = (ROOT / "scripts/laa/testflight.sh").read_text()
        self.assertLess(script.index('xcodebuild archive'), script.index('check-brand-bundle.py'))
        self.assertLess(script.index('check-brand-bundle.py'), script.index('xcodebuild -exportArchive'))
        self.assertIn('|| fail "LAA branding inspection failed', script)


if __name__ == "__main__":
    unittest.main()
