#!/usr/bin/env python3
"""Offline checks for Mac release helpers; no credentials or Apple services."""

import base64
from contextlib import redirect_stderr
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error


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
                self.assertNotIn("limit=", path)  # App Store Connect rejects it on this endpoint
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

    def test_unreadable_profile_does_not_hide_a_later_valid_candidate(self):
        bundle = profiles.BUNDLES[0]
        candidate = {"id": "app", "attributes": {"identifier": bundle, "platform": "UNIVERSAL"}}
        certificate = {"attributes": {"serialNumber": "ABC"}}
        entries = [{"id": name, "attributes": {"profileType": profiles.PROFILE_TYPE, "profileState": "ACTIVE"}}
                   for name in ("bad", "good")]

        def fake_api(_method, path):
            if "/bundleIdCapabilities?" in path:
                return {"data": [{"attributes": {"capabilityType": k}} for k in ("APP_GROUPS", "PUSH_NOTIFICATIONS")]}
            if "/bundleIds/app/profiles?" in path:
                return {"data": entries}
            if "/certificates?" in path:
                return {"data": [certificate]}
            name = "bad" if "/profiles/bad?" in path else "good"
            return {"data": {"attributes": {"profileContent": base64.b64encode(name.encode()).decode()}}}

        def allows(content, _bundle):
            if content == b"bad":
                raise profiles.ProfilesError("cannot decode")
            return content == b"good"

        with patch.object(profiles, "api", side_effect=fake_api), patch.object(profiles, "profile_allows_bundle", side_effect=allows):
            selected, profile = profiles.select_bundle_profile(bundle, [candidate], certificate)
            self.assertEqual(selected, candidate)
            self.assertEqual(base64.b64decode(profile["data"]["attributes"]["profileContent"]), b"good")
            entries.pop()
            with self.assertRaisesRegex(profiles.ProfilesError, "no usable matching provisioning profile"):
                profiles.select_bundle_profile(bundle, [candidate], certificate)

    def test_capability_permission_errors_are_explicit(self):
        bundle = profiles.BUNDLES[0]
        candidate = {"id": "app", "attributes": {"identifier": bundle, "platform": "UNIVERSAL"}}
        for status in (403, 404):
            with self.subTest(status=status), patch.object(profiles, "api", side_effect=profiles.ProfilesAPIError("fixture", status)):
                with self.assertRaisesRegex(profiles.ProfilesError, f"cannot verify bundle capabilities.*HTTP {status}"):
                    profiles.select_bundle_profile(bundle, [candidate], {"attributes": {"serialNumber": "ABC"}})

    def test_api_preserves_http_status_without_response_contents(self):
        for status in (403, 404):
            error = urllib.error.HTTPError("https://fixture.invalid", status, "fixture", {}, io.BytesIO(b'{}'))
            try:
                with self.subTest(status=status), patch.object(profiles.urllib.request, "urlopen", side_effect=error):
                    with self.assertRaises(profiles.ProfilesAPIError) as caught:
                        profiles.api("GET", "/v1/bundleIds/fixture/bundleIdCapabilities")
                    self.assertEqual(caught.exception.status, status)
            finally:
                error.close()

    def test_interactive_security_diagnostics_do_not_expose_arguments(self):
        with patch.object(keychain.subprocess, "run", return_value=SimpleNamespace(returncode=0, stderr="security> warning secret-fixture")), redirect_stderr(io.StringIO()) as output:
            keychain.security_command("create-keychain", "secret-fixture")
        self.assertIn("create-keychain", output.getvalue())
        self.assertNotIn("secret-fixture", output.getvalue())
        with patch.object(keychain.subprocess, "run", return_value=SimpleNamespace(returncode=1, stderr="secret-fixture")):
            with self.assertRaisesRegex(keychain.KeychainError, "create-keychain failed") as error:
                keychain.security_command("create-keychain", "secret-fixture")
        self.assertNotIn("secret-fixture", str(error.exception))
        with patch.object(keychain.subprocess, "run", return_value=SimpleNamespace(returncode=0, stderr="security> ")):
            keychain.security_command("command", "secret-fixture")

    def test_signing_probe_distinguishes_access_and_content_failures(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = Path(folder) / "probe"
            def fake_copy(_source, destination):
                Path(destination).write_bytes(b"fixture")
            def fake_run(args, **_kwargs):
                if args[0].endswith("xattr"):
                    return SimpleNamespace(returncode=0, stderr="")
                return SimpleNamespace(returncode=1, stderr=diagnostic)
            with patch.object(keychain.shutil, "copyfile", side_effect=fake_copy), patch.object(keychain.subprocess, "run", side_effect=fake_run):
                diagnostic = "user interaction is not allowed (-25308) secret-fixture"
                with self.assertRaisesRegex(keychain.KeychainError, "denied access") as error:
                    keychain.check_signing_key(probe, "A" * 40)
                self.assertNotIn("secret-fixture", str(error.exception))
                diagnostic = "resource fork not allowed secret-fixture"
                with redirect_stderr(io.StringIO()) as output:
                    keychain.check_signing_key(probe, "A" * 40)
                self.assertIn("unclassified", output.getvalue())
                self.assertNotIn("secret-fixture", output.getvalue())

    def test_signing_probe_times_out(self):
        with tempfile.TemporaryDirectory() as folder:
            probe = Path(folder) / "probe"
            def fake_run(args, **_kwargs):
                if args[0].endswith("xattr"):
                    return SimpleNamespace(returncode=0)
                raise subprocess.TimeoutExpired(args, 30)
            with patch.object(keychain.subprocess, "run", side_effect=fake_run):
                with self.assertRaisesRegex(keychain.KeychainError, "without interaction"):
                    keychain.check_signing_key(probe, "A" * 40)

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
                 patch.object(keychain.shutil, "copyfile", side_effect=fake_copy), redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(keychain.main(), 42)
            self.assertIn("could not fully clean up", errors.getvalue())
            self.assertEqual(search_list, ["existing-keychain", "new-concurrent-keychain"])
            self.assertEqual(list((Path(home) / ".config/laa/tmp-secrets").iterdir()), [])

    def test_release_lock_and_missing_git_recording(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder) / "repo"
            script = repo / "scripts/laa/mac-release.sh"
            script.parent.mkdir(parents=True)
            shutil.copyfile(Path(__file__).with_name("mac-release.sh"), script)
            commands = Path(folder) / "bin"
            commands.mkdir()
            xcodegen = commands / "xcodegen"
            xcodegen.write_text("#!/bin/sh\nexit 23\n")
            xcodegen.chmod(0o755)
            lock = repo / "build/laa/mac/.lock"
            lock.mkdir(parents=True)
            env = dict(os.environ, PATH=f"{commands}:/usr/bin:/bin:/usr/sbin:/sbin", CURRENT_PROJECT_VERSION="123456")
            run = lambda: subprocess.run(["/bin/bash", str(script), "--archive-only"], env=env, text=True,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            blocked = run()
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("release lock cannot be acquired", blocked.stderr)
            self.assertTrue(lock.is_dir())
            lock.rmdir()
            failed = run()
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse(lock.exists())
            info = (repo / "build/laa/mac/123456/build-info.log").read_text()
            self.assertIn("commit=unknown\n", info)
            self.assertIn("working-tree=unknown\n", info)
            self.assertIn("signing-identity-redacted=no\n", info)

    def test_notary_failure_fetches_detail_and_preserves_redacted_stderr(self):
        source = Path(__file__).with_name("mac-release.sh").read_text()
        redactor = source[source.index("redact_signing_names() {"):source.index("\ncommand -v xcodegen")]
        notarize = source[source.index("notarize() {"):source.index("\ngatekeeper() {")]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            fake = root / "xcrun"
            fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1:3] == ["notarytool", "submit"]:
    scenario = os.environ["FAKE_NOTARY"]
    if scenario in ("invalid", "invalid-zero", "accepted"):
        print(json.dumps({"status": "Accepted" if scenario == "accepted" else "Invalid", "id": "12345678-1234-1234-1234-123456789abc"}))
    if scenario == "accepted":
        sys.exit(0)
    print("Developer ID Application: Fixture Person (TEAM): failure " + os.environ["ASC_KEY_ID"], file=sys.stderr)
    sys.exit(0 if scenario == "invalid-zero" else 1)
if sys.argv[1:3] == ["notarytool", "log"]:
    pathlib.Path(os.environ["TEST_WORK"], "log-called").touch()
    print(json.dumps({"issues": [{"message": "bad signature"}]}))
    sys.exit(0)
sys.exit(2)
''')
            fake.chmod(0o755)
            notarize = notarize.replace("/usr/bin/xcrun", shlex.quote(str(fake)))
            runner = ('set -euo pipefail\nwork="$1"\nkey_path=fixture\nexport ASC_KEY_ID=fixture-keyid ASC_ISSUER_ID=fixture-issuer\n'
                      'fail() { printf "%s\\n" "$*" >&2; exit 1; }\n' + redactor + '\n' + notarize +
                      '\nnotarize "$work/input" "$work/app-notary.json"\n')
            for scenario in ("invalid", "invalid-zero", "no-json", "accepted"):
                with self.subTest(scenario=scenario):
                    work = root / scenario
                    work.mkdir()
                    env = dict(os.environ, FAKE_NOTARY=scenario, TEST_WORK=str(work))
                    result = subprocess.run(["/bin/bash", "-c", runner, "test", str(work)], env=env, text=True,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
                    self.assertEqual(result.returncode == 0, scenario == "accepted")
                    if scenario == "accepted":
                        self.assertEqual(json.loads((work / "app-notary.json").read_text())["status"], "Accepted")
                        self.assertFalse((work / "notary-stderr.tmp").exists())
                        self.assertFalse((work / "log-called").exists())
                        continue
                    diagnostic = (work / "app-notary-stderr.log").read_text()
                    self.assertIn("<redacted>", diagnostic)
                    self.assertNotIn("Fixture Person", diagnostic + result.stderr + result.stdout)
                    self.assertNotIn("fixture-keyid", diagnostic + result.stderr + result.stdout)
                    self.assertFalse((work / "notary-stderr.tmp").exists())
                    self.assertEqual((work / "log-called").exists(), scenario in ("invalid", "invalid-zero"))
                    if scenario in ("invalid", "invalid-zero"):
                        self.assertEqual(json.loads((work / "app-notary-log.json").read_text())["issues"][0]["message"], "bad signature")


if __name__ == "__main__":
    unittest.main()
