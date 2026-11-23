import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "laa" / "lab"))
import perf
import perf_frames


def report(values, noisy=None):
    rows = [{"state": "quiet", "probes": {
        key: {"value": v, "unit": "Hz" if key.endswith("_hz") else "ms"} for key in perf.PROBES}} for v in values]
    if noisy is not None:
        rows.insert(2, {"state": "noisy", "probes": {
            key: {"value": noisy, "unit": "other"} for key in perf.PROBES}})
    return {"schema": 2, "protocol": perf.PROTOCOL, "configuration": "Debug+O", "environment": "fixture", "runs": rows}


class Statistics(unittest.TestCase):
    def test_stat_range_and_median(self):
        self.assertEqual(perf.stats([8, 1, 4, 0, 27, 3]), {
            "median": 3.5, "min": 0, "max": 27, "spread": 27, "count": 6, "samples": [8, 1, 4, 0, 27, 3]})

    def test_reject_nonfinite_missing_or_negative_values(self):
        for values in ([1] * 4, [0, 1, 2, 3, float("nan")], [0, 1, 2, 3, -1], [1, 2, 3, 4, False]):
            with self.subTest(values=values), self.assertRaises(ValueError):
                perf.stats(values)

    def test_only_quiet_runs_count(self):
        result = perf.aggregate(report([8, 9, 10, 11, 12], noisy=99999)["runs"])
        self.assertEqual(result["doc_open_long"]["median"], 10)
        self.assertEqual(result["doc_open_long"]["count"], 5)
        with self.assertRaisesRegex(ValueError, "4 quiet runs"):
            perf.aggregate(report([8, 9, 10, 11], noisy=12)["runs"])

    def test_missing_probe_has_explicit_unavailable_and_not_a_zero(self):
        runs = report([8, 9, 10, 11, 12])["runs"]
        runs[0]["probes"].pop("doc_open_long")
        runs[0]["unavailable"] = {"doc_open_long": "XCTest marker missing"}
        summary = perf.aggregate(runs)
        self.assertEqual(summary["doc_open_long"], {"state": "unavailable", "count": 4,
                                                    "reason": "Need 5 samples: XCTest marker missing (1)"})
        self.assertEqual(summary["work_open_long_history"]["count"], 5)
        self.assertEqual(perf.lost_probes(perf.aggregate(report([8] * 5)["runs"]), summary), ["doc_open_long"])
        self.assertEqual(perf.lost_probes({}, summary), [])

    def test_changed_units_make_one_probe_unavailable(self):
        runs = report([8, 9, 10, 11, 12])["runs"]
        runs[1]["probes"]["doc_open_long"]["unit"] = "s"
        self.assertEqual(perf.aggregate(runs)["doc_open_long"]["state"], "unavailable")


class Compare(unittest.TestCase):
    def test_range_band_strict_threshold_and_direction(self):
        base = report([1, 2, 3, 4, 5])
        in_band = report([5, 6, 7, 8, 9])
        slower = report([6, 7, 8, 9, 10])
        self.assertFalse(any(x["regression"] for x in perf.compare_reports(base, in_band)))
        compared = {x["probe"]: x for x in perf.compare_reports(base, slower)}
        self.assertTrue(compared["doc_open_long"]["regression"])
        self.assertEqual(compared["doc_open_long"]["noise_band"], 4)
        self.assertFalse(compared["chat_scroll_proxy_observed_hz"]["regression"])
        self.assertEqual(compared["chat_scroll_proxy_expected_hz"]["state"], "context")
        reversed_changes = {x["probe"]: x for x in perf.compare_reports(slower, base)}
        self.assertTrue(reversed_changes["chat_scroll_proxy_observed_hz"]["regression"])
        self.assertFalse(reversed_changes["doc_open_long"]["regression"])

    def test_noisy_candidate_uses_larger_range(self):
        base = report([1, 2, 3, 4, 5])
        after = report([1, 13, 14, 15, 42])
        self.assertTrue(all(x["noise_band"] == 41 and not x["regression"] for x in perf.compare_reports(base, after)))

    def test_differing_environment_is_not_comparable(self):
        base = report([1, 2, 3, 4, 5])
        after = {**base, "environment": "another runtime"}
        with self.assertRaisesRegex(ValueError, "Incompatible reports"):
            perf.compare_reports(base, after)

    def test_compare_uses_raw_runs_and_never_passes_unavailable(self):
        base = {**report([1, 2, 3, 4, 5]), "probes": {"doc_open_long": {"median": 1000}}}
        after = report([1, 2, 3, 4, 5])
        for row in after["runs"]:
            row["probes"].pop("doc_open_long")
        changes = perf.compare_reports(base, after)
        row = next(x for x in changes if x["probe"] == "doc_open_long")
        self.assertEqual(row["state"], "not_comparable")
        self.assertNotIn("regression", row)
        self.assertTrue(row["lost"])
        self.assertTrue(all(x["delta"] == 0 for x in changes if x is not row))


class Collection(unittest.TestCase):
    def test_native_metrics_select_by_test_url_and_keep_absence(self):
        def result(name, metric, label, unit, value):
            return {"testIdentifier": "LAAPerformanceUITests/" + name + "()",
                    "testIdentifierURL": "test://com.apple.xcode/Conduit/" + perf.TEST_CLASS + "/" + name,
                    "testRuns": [{"metrics": [{"identifier": metric, "displayName": label,
                                              "unitOfMeasurement": unit, "measurements": [value]}]}]}
        cold = result("testColdLaunch", "com.apple.dt.XCTMetric_ApplicationLaunch-ApplicationFirstFramePresentationResponsive.duration",
                      "Duration (ApplicationFirstFramePresentationResponsive)", "s", 1.5)
        chat = result("testScrollChat", "synthetic.hitch.ratio", "Hitch Time Ratio", "ms/s", 3)
        work = result("testScrollWork", "synthetic-Scroll_DraggingAndDeceleration.duration", "Duration", "s", 1)
        samples, missing = perf.parsed_native_metrics([cold, chat, work])
        self.assertEqual({name: row["value"] for name, row in samples.items()}, {
            "cold_launch_first_usable": 1500, "chat_scroll_hitch_ratio": 3, "work_scroll_signpost_duration": 1000})
        self.assertIn("exported: Duration", missing["work_scroll_hitch_ratio"])

    def test_duplicate_wall_marker_fails_missing_marker_does_not(self):
        def line(probe):
            return "prefix LAA_LAB_PERF " + json.dumps({"probe": probe, "ms": 6})
        log = "\n".join(line(probe) for probe in perf.WALL)
        self.assertEqual(perf.timing_log(log)["doc_open_long"]["value"], 6)
        with self.assertRaisesRegex(ValueError, "Duplicate timing"):
            perf.timing_log(log + "\n" + line("doc_open_long"))
        self.assertEqual(set(perf.timing_log(line("doc_open_long"))), {"doc_open_long"})

    def test_fixture_env_does_not_inherit_production_opt_ins(self):
        with patch.dict(perf.os.environ, {"LAA_UI_TEST_REAL_BRIDGE": "1", "LAA_BRIDGE_DEFAULT_ADDRESS": "https://production.invalid",
                                         "TEST_RUNNER_LAA_PERF_RUN": "1"}):
            self.assertFalse({"LAA_UI_TEST_REAL_BRIDGE", "LAA_BRIDGE_DEFAULT_ADDRESS", "TEST_RUNNER_LAA_PERF_RUN"} & perf.lab_env().keys())

    def test_cleanup_namespaces_match_and_requires_app_receipt(self):
        namespace = "9413CB00-2DA1-4A02-A91C-1A9B08E7D7AC"
        with TemporaryDirectory() as temp:
            root = Path(temp)
            receipt = root / "Library" / "Caches" / f"laa-perf-cleanup-{namespace}.txt"
            receipt.parent.mkdir(parents=True)
            log = root / "simulator.log"

            def launch(*args, extra, **kwargs):
                self.assertEqual(extra["SIMCTL_CHILD_LAA_LAB_KEYCHAIN_NAMESPACE"], namespace)
                self.assertEqual(extra["SIMCTL_CHILD_LAA_PERF_KEYCHAIN_NAMESPACE"], namespace)
                self.assertFalse(receipt.exists(), "stale receipts must not be accepted")
                receipt.write_text("deleted")

            receipt.write_text("stale")
            with patch.object(perf, "frame_container", return_value=temp), patch.object(perf, "log_run", side_effect=launch):
                perf.clear_credentials("phone", namespace, log)
            self.assertFalse(receipt.exists())
            self.assertIn("Keychain cleanup: deleted", log.read_text())
            with patch.object(perf, "frame_container", return_value=temp), patch.object(perf, "log_run"), \
                    patch.object(perf.time, "monotonic", side_effect=[0, 11]):
                with self.assertRaisesRegex(RuntimeError, "not acknowledged"):
                    perf.clear_credentials("phone", namespace, log)

    def test_quiet_gate_waits_until_xcode_sim_and_load_clear(self):
        readings = [{"load1": 1, "other_simulators": 1, "other_xcodebuild": 0},
                    {"load1": 1, "other_simulators": 0, "other_xcodebuild": 1},
                    {"load1": perf.LOAD_LIMIT + 1, "other_simulators": 0, "other_xcodebuild": 0},
                    {"load1": perf.LOAD_LIMIT, "other_simulators": 0, "other_xcodebuild": 0}]
        with patch.object(perf, "busy_snapshot", side_effect=readings), patch.object(perf.time, "sleep", return_value=None):
            self.assertEqual(perf.wait_quiet("phone", float("inf")), (True, readings))
        with patch.object(perf, "busy_snapshot", return_value=readings[0]):
            self.assertEqual(perf.wait_quiet("phone", 0), (False, readings[:1]))


class FrameProxy(unittest.TestCase):
    trace = {"started": 0, "stopped": 1.5, "overflow": False, "intervals": [
        {"end": .25, "actual": .25, "expected": .125},
        {"end": .625, "actual": .375, "expected": .125},
        {"end": .75, "actual": .125, "expected": .125},
        {"end": 1.125, "actual": .375, "expected": .125},
        {"end": 1.25, "actual": .125, "expected": .125},
    ]}

    def test_clips_hitch_time_to_window_and_counts_completed_intervals(self):
        result = perf_frames.summarize(self.trace, {"start": .1875, "end": .9375})
        self.assertAlmostEqual(result["hitch_ratio"], 1000 * (.0625 + .25 + .0625) / .75)
        self.assertEqual((result["late_1_5x"], result["late_2x"], result["worst_frame"], result["expected_hz"]), (2, 1, 375, 8))
        self.assertEqual(result["observed_hz"], 4)

    def test_incomplete_trace_not_a_zero_sample(self):
        with self.assertRaisesRegex(ValueError, "not cover"):
            perf_frames.summarize(self.trace, {"start": .25, "end": 1.4375})
        with self.assertRaisesRegex(ValueError, "overflow"):
            perf_frames.summarize({**self.trace, "overflow": True}, {"start": .25, "end": .75})


if __name__ == "__main__":
    unittest.main()
