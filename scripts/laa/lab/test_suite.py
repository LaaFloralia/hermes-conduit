"""Runner tests with no Xcode, Simulator, remote route, or lab services."""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import suite


class SuiteTest(unittest.TestCase):
    def test_simulator_entries_are_abolished_before_any_side_effect(self):
        for argv in (["run", "integration", "--out", "/not-created/suite"], ["run", "integration", "--_worker-source", "{}"],
                     ["worker"], ["seed", "integration", "/not-created/suite"], ["run"]):
            stderr = io.StringIO()
            with self.subTest(argv=argv), contextlib.redirect_stderr(stderr), \
                 patch.object(suite.subprocess, "Popen") as popen, patch.object(suite.subprocess, "run") as run, \
                 patch.object(suite.fcntl, "flock") as flock, patch.object(suite, "Simulator") as sim:
                self.assertEqual(suite.main(argv), 64)
                for called in (popen, run, flock, sim):
                    called.assert_not_called()
            self.assertIn("2026-11-27に廃止", stderr.getvalue())
            self.assertIn("laa-app-gate pre hortensia --src", stderr.getvalue())
        self.assertFalse(Path("/not-created/suite").exists())

    def test_parse_and_check_stay_available(self):
        with tempfile.TemporaryDirectory() as out:
            (Path(out) / "results.json").write_text(json.dumps({"tests": {}}))
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertNotEqual(suite.main(["check", "integration", out, "--partial"]), 64)
                self.assertNotEqual(suite.main(["parse", out]), 64)

    def test_dry_run_uses_no_process_or_lock(self):
        for host in ("auto", "macbook", "mini"):
            stdout = io.StringIO()
            with self.subTest(host=host), contextlib.redirect_stdout(stdout), \
                 patch.object(suite.subprocess, "Popen") as subprocess_start, \
                 patch.object(suite.fcntl, "flock") as flock, patch.dict(os.environ, {}, clear=True):
                args = suite.build_parser()[0].parse_args(["run", "integration", "--out", "/not-created/suite",
                                                           "--phase", "unit", "--host", host, "--dry-run"])
                self.assertEqual(suite.cmd_run(args), 0)
                subprocess_start.assert_not_called()
                flock.assert_not_called()
            plan = json.loads(stdout.getvalue())
            cmd = plan["command"]
            self.assertEqual("--fallback-mini" in cmd, host == "auto")
            if host == "mini":
                self.assertEqual(plan["env"]["LAA_MB_HOST"], "mini")
            else:
                self.assertEqual(cmd[cmd.index("--scheme") + 1], "Conduit")
                self.assertEqual(cmd[cmd.index("--cache-key") + 1], "hermes-conduit")
                self.assertEqual(cmd[cmd.index("--clean-retry-exit") + 1], str(suite.BUILD_FAILURE))
            self.assertEqual(len(plan["batches"]["unit"][0]), 28)
            self.assertEqual(set(plan["batches"]), {"unit"})

    def test_explicit_selectors_split_by_target_and_class(self):
        selectors = [f"ConduitTests/Class{i}" for i in range(57)]
        selectors += ["ConduitTests/Class0/testOne()", "ConduitUITests/UITest"]
        unit = suite.batches({}, "unit", selectors)
        ui = suite.batches({}, "ui", selectors)
        self.assertEqual([len(x) for x in unit], [29, 28, 1])
        self.assertIn("-only-testing:ConduitTests/Class0/testOne()", unit[0])
        self.assertEqual(ui, [["-only-testing:ConduitUITests/UITest"]])

    def test_one_build_and_manifest_for_enumeration_and_all_unit_batches(self):
        with tempfile.TemporaryDirectory() as scratch:
            out, manifest = Path(scratch).resolve() / "out", Path(scratch) / "built.xctestrun"
            args = argparse.Namespace(suite="integration", phase="unit", only=[], no_erase=False, no_rerun=True,
                                      _worker_source='{"sha":"fixture","dirty":false}')
            route = dict(LAA_MB_HOST="mini", LAA_BUILD_SLOT_HELD="1", LAA_MB_SRC=str(suite.REPO),
                         LAA_MB_DD=scratch, LAA_MB_PACKAGES=scratch, LAA_MB_OUT=str(out))
            sim = MagicMock(owned=False)
            inventory = [f"ConduitTests/Class{i:02d}/test" for i in range(57)]
            with patch.dict(os.environ, route, clear=True), patch.object(suite, "Simulator", return_value=sim), \
                 patch.object(suite, "build_for_testing", return_value=(0, manifest)) as build, \
                 patch.object(suite, "enumerate_tests") as enumerate_tests, \
                 patch.object(suite, "inventory", return_value=inventory), patch.object(suite, "start_fixtures") as fixtures, \
                 patch.object(suite, "run_tests", return_value=0) as run_tests, patch.object(suite, "ran", return_value=True), \
                 patch.object(suite, "cmd_parse"), patch.object(suite.signal, "signal"), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(suite.cmd_worker(args, suite.suites()["integration"]), 0)
                build.assert_called_once()
                enumerate_tests.assert_called_once_with(sim, manifest, out, "ConduitTests")
                self.assertEqual([len(c.args[2]) for c in run_tests.call_args_list], [28, 28, 1])
                self.assertTrue(all(c.args[1] == manifest for c in run_tests.call_args_list))
                fixtures.assert_not_called()
                sim.start.assert_called_once_with(erase=True)
                sim.stop.assert_called_once_with()
                run_tests.side_effect = RuntimeError("fixture failure")
                with self.assertRaisesRegex(RuntimeError, "fixture failure"):
                    suite.cmd_worker(args, suite.suites()["integration"])
                self.assertEqual(sim.stop.call_count, 2)

    def test_an_already_booted_simulator_is_not_touched(self):
        device = dict(udid="selected", name=suite.PHONE_NAME, isAvailable=True, state="Booted")
        with patch.object(suite, "sim_devices", return_value={suite.PHONE_RUNTIME: [device]}), patch.object(suite, "sh") as sh:
            sim = suite.Simulator(Path("/unused"))
            with self.assertRaisesRegex(RuntimeError, "will not take over"):
                sim.start(erase=True)
            sim.stop()
            sh.assert_not_called()

    def test_real_bridge_and_stale_lane_environment_are_stripped(self):
        with patch.dict(os.environ, {
            "LAA_REAL_BRIDGE_TEST": "1", "TEST_RUNNER_LAA_UI_TEST_REAL_BRIDGE": "1",
            "TEST_RUNNER_LAA_LANE_ID": "unrelated", "LAA_LAB_SIMULATOR": "unrelated",
        }, clear=True):
            isolated = suite.env({"TEST_RUNNER_LAA_LANE_ID": "owned"})
        self.assertEqual(isolated, {"DEVELOPER_DIR": suite.DEVELOPER_DIR, "TEST_RUNNER_LAA_LANE_ID": "owned"})


if __name__ == "__main__":
    unittest.main()
