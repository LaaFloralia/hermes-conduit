#!/usr/bin/env python3
"""Offline checks for Mac release helpers; no credentials or Apple services."""

import base64
from contextlib import redirect_stderr
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


profiles = load("mac_profiles", "mac-profiles.py")
keychain = load("mac_signing_keychain", "mac-signing-keychain.py")


class ReleaseHelpersTests(unittest.TestCase):
    def test_der_signature_with_sign_padding(self):
        r = b"\x80" + b"\x01" * 31
        s = b"\x02" * 32
        encoded = b"\x30\x45\x02\x21\x00" + r + b"\x02\x20" + s
        self.assertEqual(profiles.der_integers(encoded), [r, s])
        for bad in (encoded[:-1], encoded + b"\x00", b"\x30\x06\x02\x01\x80\x02\x01\x01"):
            with self.subTest(bad=bad), self.assertRaises(profiles.ProfilesError):
                profiles.der_integers(bad)

    def test_existing_profile_file_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "profile.provisionprofile"
            profiles.install_profile(path, b"first")
            profiles.install_profile(path, b"different")
            self.assertEqual(path.read_bytes(), b"first")

    def test_profile_entitlements_are_checked_for_each_bundle(self):
        app_entitlements = {
            "com.apple.security.application-groups": [profiles.NOTIFICATION_GROUP, profiles.LAUNCHER_GROUP],
            "aps-environment": "production",
        }
        def check(bundle, entitlements):
            result = SimpleNamespace(returncode=0, stdout=plistlib.dumps({"Entitlements": entitlements}))
            with patch.object(profiles.subprocess, "run", return_value=result):
                return profiles.profile_allows_bundle(b"fixture", bundle)
        self.assertTrue(check(profiles.BUNDLES[0], app_entitlements))
        self.assertTrue(check(profiles.BUNDLES[1], {"com.apple.security.application-groups": [profiles.NOTIFICATION_GROUP]}))
        self.assertFalse(check(profiles.BUNDLES[0], {**app_entitlements, "aps-environment": "development"}))
        self.assertFalse(check(profiles.BUNDLES[0], {**app_entitlements, "com.apple.security.application-groups": [profiles.NOTIFICATION_GROUP]}))

    def test_existing_catalyst_profile_beats_platform_guess(self):
        bundle = profiles.BUNDLES[0]
        candidates = [
            {"id": "mac", "attributes": {"identifier": bundle, "platform": "MAC_OS"}},
            {"id": "ios", "attributes": {"identifier": bundle, "platform": "IOS"}},
        ]
        certificate = {"attributes": {"serialNumber": "ABC"}}
        detail = {"data": {"attributes": {"profileContent": base64.b64encode(b"profile").decode()}}}
        def fake_api(method, path):
            self.assertEqual(method, "GET")
            if "/bundleIdCapabilities?" in path:
                return {"data": [{"attributes": {"capabilityType": kind}} for kind in ("APP_GROUPS", "PUSH_NOTIFICATIONS")]}
            if path.startswith("/v1/bundleIds/mac/profiles?"):
                return {"data": []}
            if path.startswith("/v1/bundleIds/ios/profiles?"):
                return {"data": [{"id": "p", "attributes": {"profileType": profiles.PROFILE_TYPE, "profileState": "ACTIVE"}}]}
            if path.startswith("/v1/profiles/p/certificates?"):
                return {"data": [{"attributes": {"serialNumber": "abc"}}]}
            if path.startswith("/v1/profiles/p?"):
                return detail
            self.fail("unexpected API route")
        with patch.object(profiles, "api", side_effect=fake_api), patch.object(profiles, "profile_allows_bundle", return_value=True):
            selected, profile = profiles.select_bundle_profile(bundle, candidates, certificate)
        self.assertEqual(selected["id"], "ios")
        self.assertEqual(profile, detail)

    def test_extension_does_not_require_its_own_push_capability(self):
        bundle = profiles.BUNDLES[1]
        candidate = {"id": "nse", "attributes": {"identifier": bundle, "platform": "UNIVERSAL"}}
        def fake_api(_method, path):
            if "/bundleIdCapabilities?" in path:
                return {"data": [{"attributes": {"capabilityType": "APP_GROUPS"}}]}
            return {"data": []}
        with patch.object(profiles, "api", side_effect=fake_api):
            selected, profile = profiles.select_bundle_profile(bundle, [candidate], {"attributes": {"serialNumber": "ABC"}})
        self.assertEqual(selected, candidate)
        self.assertIsNone(profile)

    def test_missing_capability_and_ambiguous_app_ids_stop_before_creation(self):
        bundle = profiles.BUNDLES[0]
        candidates = [
            {"id": name, "attributes": {"identifier": bundle, "platform": "UNIVERSAL"}}
            for name in ("first", "second")
        ]
        certificate = {"attributes": {"serialNumber": "ABC"}}
        with patch.object(profiles, "api", return_value={"data": []}):
            with self.assertRaises(profiles.ProfilesError):
                profiles.select_bundle_profile(bundle, candidates, certificate)

        def fake_api(_method, path):
            if "/bundleIdCapabilities?" in path:
                return {"data": [{"attributes": {"capabilityType": kind}} for kind in ("APP_GROUPS", "PUSH_NOTIFICATIONS")]}
            return {"data": []}
        with patch.object(profiles, "api", side_effect=fake_api):
            with self.assertRaises(profiles.ProfilesError):
                profiles.select_bundle_profile(bundle, candidates, certificate)

    def test_interactive_security_error_is_detected_without_echo(self):
        with patch.object(keychain.subprocess, "run", return_value=SimpleNamespace(returncode=0, stderr="security> failure")):
            with self.assertRaises(keychain.KeychainError):
                keychain.security_command("command", "secret-fixture")
        with patch.object(keychain.subprocess, "run", return_value=SimpleNamespace(returncode=0, stderr="security> ")):
            keychain.security_command("command", "secret-fixture")

    def test_cleanup_preserves_child_failure_and_other_keychains(self):
        with tempfile.TemporaryDirectory() as home:
            search_list = ["existing-keychain"]

            def set_list(paths):
                search_list[:] = paths

            class Child:
                returncode = None

                def wait(self):
                    search_list.append("new-concurrent-keychain")
                    self.returncode = 42
                    return self.returncode

                def poll(self):
                    return self.returncode

            def fake_run(args, **_kwargs):
                if "find-identity" in args:
                    return SimpleNamespace(returncode=0, stdout='  1) ' + 'A' * 40 + ' "Developer ID Application: fixture"')
                if "delete-keychain" in args:
                    return SimpleNamespace(returncode=1)
                return SimpleNamespace(returncode=0)

            def fake_copy(_source, destination):
                Path(destination).write_bytes(b"fixture")

            env = {"LAA_DEVID_P12_B64": base64.b64encode(b"fixture").decode(), "LAA_DEVID_P12_PASSWORD": "fixture"}
            with patch.dict(os.environ, env), patch.object(keychain.Path, "home", return_value=Path(home)), \
                 patch.object(keychain.sys, "argv", ["wrapper", "release"]), \
                 patch.object(keychain, "OPENSSL", "/usr/bin/true"), \
                 patch.object(keychain, "security_command"), \
                 patch.object(keychain, "keychains", side_effect=lambda: list(search_list)), \
                 patch.object(keychain, "set_keychains", side_effect=set_list), \
                 patch.object(keychain.subprocess, "run", side_effect=fake_run), \
                 patch.object(keychain.subprocess, "Popen", return_value=Child()), \
                 patch.object(keychain.shutil, "copy2", side_effect=fake_copy), redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(keychain.main(), 42)
            self.assertIn("could not fully clean up", errors.getvalue())
            self.assertEqual(search_list, ["existing-keychain", "new-concurrent-keychain"])
            self.assertEqual(list((Path(home) / ".config/laa/tmp-secrets").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
