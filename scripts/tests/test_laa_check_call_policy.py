import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("laa_check_call_policy", ROOT / "scripts/laa/check-call-policy.py")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


def profile(root: Path, name: str, settings=None, raw=None) -> None:
    directory = root / name
    directory.mkdir()
    if raw is not None:
        (directory / "conduit-calls.json").write_text(raw, encoding="utf-8")
    elif settings is not None:
        (directory / "conduit-calls.json").write_text(json.dumps({"v": 1, "settings": settings}), encoding="utf-8")


class LAACallPolicyTests(unittest.TestCase):
    def test_calls_when_asked_pass_and_a_profile_without_settings_uses_the_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile(root, "laa-monet", {"enabled": True, "when_asked": True, "decides": False, "alerts": False})
            profile(root, "laa-monet-dots")
            profile(root, "other", {"enabled": True, "when_asked": True, "decides": True, "alerts": True})
            result = policy.check(root)
            self.assertEqual([row["profile"] for row in result["profiles"]], ["laa-monet", "laa-monet-dots"])
            self.assertEqual(result["violations"], [])
            self.assertFalse(result["profiles"][1]["saved"])
            self.assertFalse(result["profiles"][1]["enabled"])
            self.assertEqual(policy.main(["--profiles-dir", tmp, "--json"]), 0)

    def test_calling_on_its_own_or_about_alerts_is_a_violation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile(root, "laa-cto", {"enabled": True, "when_asked": True, "decides": True, "alerts": False})
            profile(root, "laa-cos", {"enabled": True, "when_asked": True, "decides": False, "alerts": True})
            result = policy.check(root)
            self.assertEqual(result["violations"], [{"profile": "laa-cos", "setting": "alerts"},
                                                    {"profile": "laa-cto", "setting": "decides"}])
            self.assertEqual(policy.main(["--profiles-dir", tmp]), 1)

    def test_an_unreadable_file_is_not_taken_for_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile(root, "laa-cfo", raw="{not json")
            profile(root, "laa-cio", raw=json.dumps({"v": 1}))
            result = policy.check(root)
            self.assertEqual(result["unreadable"], ["laa-cfo", "laa-cio"])
            self.assertEqual(policy.main(["--profiles-dir", tmp]), 2)

    def test_the_check_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            profile(root, "laa-monet", {"enabled": True, "when_asked": True, "decides": False, "alerts": False})
            before = sorted((path, path.stat().st_mtime_ns) for path in root.rglob("*"))
            policy.main(["--profiles-dir", tmp])
            self.assertEqual(before, sorted((path, path.stat().st_mtime_ns) for path in root.rglob("*")))


if __name__ == "__main__":
    unittest.main()
