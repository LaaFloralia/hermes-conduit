"""The ratchet in scripts/laa/lab/suite.py: a count is never the verdict."""
import argparse
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("lab_suite", ROOT / "scripts/laa/lab/suite.py")
suite = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(suite)

A, B, C = "ConduitTests/AlphaTests/testOne", "ConduitTests/AlphaTests/testTwo", "ConduitTests/BetaTests/testThree"


def failed(fingerprint="aaaaaaaaaaaa", message="XCTAssertTrue failed"):
    return {"result": "Failed", "fingerprint": fingerprint, "message": message, "failures": 1}


def listed(fingerprint="aaaaaaaaaaaa", result="Failed", kind="real-bug", reason="written reason"):
    return {"result": result, "fingerprint": fingerprint, "class": kind, "reason": reason}


class RatchetTests(unittest.TestCase):
    def check(self, tests, known, inventory=(A, B, C), partial=False, exclude=None):
        with tempfile.TemporaryDirectory() as tmp:
            lab, out = Path(tmp) / "lab", Path(tmp) / "out"
            lab.mkdir(), out.mkdir()
            (lab / "known-failures.json").write_text(json.dumps({"demo": known}))
            (lab / "suites.json").write_text(json.dumps({"demo": {
                "spec": "x.yml", "unit": ["AlphaTests", "BetaTests"], "ui": [], "exclude_classes": exclude or {}}}))
            (out / "results.json").write_text(json.dumps({"counts": {}, "tests": tests}))
            (out / "inventory-ConduitTests.json").write_text(json.dumps(
                {"values": [{"enabledTests": [{"identifier": i + "()"} for i in inventory]}]}))
            text = io.StringIO()
            with mock.patch.object(suite, "LAB", lab), contextlib.redirect_stdout(text):
                code = suite.cmd_check(argparse.Namespace(suite="demo", out=str(out), partial=partial))
            return code, text.getvalue()

    passed = {"result": "Passed"}

    def test_all_passing_is_green(self):
        code, _ = self.check({A: self.passed, B: self.passed, C: self.passed}, {})
        self.assertEqual(code, 0)

    def test_an_unlisted_failure_fails_even_when_the_count_is_unchanged(self):
        # One listed failure was fixed and another test broke: still "1 failed".
        code, text = self.check({A: self.passed, B: failed("bbbbbbbbbbbb"), C: self.passed}, {A: listed()})
        self.assertEqual(code, 1)
        self.assertIn(f"NEW FAILED: {B}", text)
        self.assertIn(f"NOW PASSES, remove from known-failures.json: {A}", text)

    def test_a_listed_test_failing_for_another_reason_fails(self):
        code, text = self.check({A: failed("cccccccccccc"), B: self.passed, C: self.passed}, {A: listed("aaaaaaaaaaaa")})
        self.assertEqual(code, 1)
        self.assertIn(f"DIFFERENT FAILURE: {A}", text)

    def test_a_wildcard_fingerprint_explains_nothing(self):
        code, text = self.check({A: failed(), B: self.passed, C: self.passed}, {A: listed("*")})
        self.assertEqual(code, 1)
        self.assertIn("DIFFERENT FAILURE", text)

    def test_a_listed_failure_with_the_same_fingerprint_is_accepted(self):
        code, _ = self.check({A: failed(), B: self.passed, C: self.passed}, {A: listed()})
        self.assertEqual(code, 0)

    def test_a_skip_must_be_listed_as_a_skip(self):
        skipped = {"result": "Skipped", "fingerprint": None, "message": "opt-in"}
        code, text = self.check({A: skipped, B: self.passed, C: self.passed}, {})
        self.assertEqual(code, 1)
        self.assertIn(f"NEW SKIPPED: {A}", text)
        code, text = self.check({A: skipped, B: self.passed, C: self.passed}, {A: listed()})
        self.assertIn("CHANGED RESULT", text)
        code, _ = self.check({A: skipped, B: self.passed, C: self.passed},
                             {A: listed(None, "Skipped", "not-applicable")})
        self.assertEqual(code, 0)

    def test_a_test_in_the_build_that_did_not_run_fails(self):
        code, text = self.check({A: self.passed, B: self.passed}, {})
        self.assertEqual(code, 1)
        self.assertIn(f"IN THE BUILD BUT DID NOT RUN: {C}", text)
        code, _ = self.check({A: self.passed, B: self.passed}, {}, partial=True)
        self.assertEqual(code, 0)

    def test_a_listed_test_that_did_not_run_fails(self):
        code, text = self.check({A: self.passed, B: self.passed}, {C: listed()}, inventory=(A, B))
        self.assertEqual(code, 1)
        self.assertIn(f"LISTED BUT DID NOT RUN: {C}", text)

    def test_an_entry_needs_a_class_and_a_reason(self):
        for entry in (listed(reason=""), listed(kind="flaky")):
            code, text = self.check({A: failed(), B: self.passed, C: self.passed}, {A: entry})
            self.assertEqual(code, 1)
            self.assertIn("LISTED WITHOUT A REASON OR CLASS", text)

    def test_an_excluded_class_needs_a_reason_and_must_not_run(self):
        code, text = self.check({A: self.passed, B: self.passed, C: self.passed}, {}, exclude={"BetaTests": " "})
        self.assertEqual(code, 1)
        self.assertIn("EXCLUDED CLASS WITHOUT A REASON: BetaTests", text)
        self.assertIn("EXCLUDED CLASS RAN: BetaTests", text)

    def test_a_runner_that_never_started_is_a_failure(self):
        pseudo = "ConduitTests/Conduit encountered an error"
        code, text = self.check({pseudo: failed("dddddddddddd", "Failed to install or launch the test runner")}, {}, partial=True)
        self.assertEqual(code, 1)
        self.assertIn("NEW FAILED: " + pseudo, text)

    def test_a_pass_that_needed_the_rerun_stays_visible(self):
        rerun = {"result": "Passed", "rerun": {"result": "Failed", "fingerprint": "eeeeeeeeeeee", "message": "timed out"}}
        code, text = self.check({A: rerun, B: self.passed, C: self.passed}, {})
        self.assertEqual(code, 0)
        self.assertIn("passed only on rerun 1", text)
        self.assertIn(f"PASSED ONLY ON RERUN (record it; fix it if it repeats): {A} first [eeeeeeeeeeee] timed out", text)


class ResultTests(unittest.TestCase):
    @staticmethod
    def case(name, result, message=None):
        children = [{"nodeType": "Failure Message", "name": message}] if message else []
        return {"nodeType": "Unit test bundle", "name": "ConduitTests", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": name, "result": result, "children": children}]}

    def test_fingerprints_ignore_addresses_numbers_and_paths(self):
        one = suite.fingerprint('XCTAssertEqual failed: ("107.3") is not equal to ("100.0") at 0x10838 /Users/a/x/ChatTests.swift:41')
        two = suite.fingerprint('XCTAssertEqual failed: ("99")  is not equal to ("100.0") at 0x2 /private/b/ChatTests.swift:7')
        self.assertEqual(one, two)
        self.assertNotEqual(one, suite.fingerprint("XCTAssertTrue failed - Login screen did not appear"))

    def test_only_a_rerun_bundle_marks_a_recovered_test(self):
        found = {}
        suite.walk(self.case("AlphaTests/testOne()", "Failed", "boom 12"), "", found)
        first = found[A]["fingerprint"]
        suite.walk(self.case("AlphaTests/testOne()", "Passed"), "", found, rerun=True)
        self.assertEqual(found[A]["result"], "Passed")
        self.assertEqual(found[A]["rerun"], {"result": "Failed", "fingerprint": first, "message": "boom 12"})
        # A second pass must not erase the record.
        suite.walk(self.case("AlphaTests/testOne()", "Passed"), "", found, rerun=True)
        self.assertEqual(found[A]["rerun"]["fingerprint"], first)

    def test_a_later_ordinary_bundle_replaces_the_result_without_a_mark(self):
        found = {}
        suite.walk(self.case("AlphaTests/testOne()", "Failed", "boom"), "", found)
        suite.walk(self.case("AlphaTests/testOne()", "Passed"), "", found)
        self.assertNotIn("rerun", found[A])

    def test_a_rerun_that_fails_again_stays_failed(self):
        found = {}
        suite.walk(self.case("AlphaTests/testOne()", "Failed", "boom"), "", found)
        suite.walk(self.case("AlphaTests/testOne()", "Failed", "boom"), "", found, rerun=True)
        self.assertEqual(found[A]["result"], "Failed")

    def test_only_unexplained_failures_are_rerun(self):
        tests = {A: failed("aaaaaaaaaaaa"), B: failed("bbbbbbbbbbbb"), C: {"result": "Skipped", "fingerprint": None},
                 "ConduitTests/Conduit encountered an error": failed("dddddddddddd"),
                 "ConduitUITests/GammaUITests/testFour": failed("ffffffffffff")}
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "known-failures.json").write_text(json.dumps({"demo": {A: listed("aaaaaaaaaaaa"), B: listed("000000000000")}}))
            with mock.patch.object(suite, "LAB", Path(tmp)):
                self.assertEqual(suite.unexpected("demo", tests, "ConduitTests"), [B])
                self.assertEqual(suite.unexpected("demo", tests, "ConduitUITests"), ["ConduitUITests/GammaUITests/testFour"])

    def test_real_bridge_opt_ins_never_reach_a_run(self):
        with mock.patch.dict(suite.os.environ, {"LAA_UI_TEST_REAL_BRIDGE": "1", "TEST_RUNNER_LAA_REAL_BRIDGE_TEST": "1", "KEEP": "1"}):
            env = suite.env()
        self.assertNotIn("LAA_UI_TEST_REAL_BRIDGE", env)
        self.assertNotIn("TEST_RUNNER_LAA_REAL_BRIDGE_TEST", env)
        self.assertEqual(env["KEEP"], "1")


if __name__ == "__main__":
    unittest.main()
