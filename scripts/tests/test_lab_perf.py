import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "laa" / "lab"))
import perf


def report(values, noisy=None):
    rows = [{"state": "quiet", "probes": {
        key: {"value": v, "unit": "ms/s" if "ratio" in key else "ms"} for key in perf.REQUIRED}} for v in values]
    if noisy is not None:
        rows.insert(2, {"state": "noisy", "probes": {
            key: {"value": noisy, "unit": "ms"} for key in perf.REQUIRED}})
    return {"schema": 1, "protocol": "test", "configuration": "Debug+O", "environment": "fixture", "runs": rows}


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

    def test_missing_probe_fails(self):
        runs = report([8, 9, 10, 11, 12])["runs"]
        runs[0]["probes"].pop("doc_open_long")
        with self.assertRaisesRegex(ValueError, "Missing required probes"):
            perf.aggregate(runs)

    def test_bad_probe_units_fail(self):
        runs = report([8, 9, 10, 11, 12])["runs"]
        runs[1]["probes"]["doc_open_long"]["unit"] = "s"
        with self.assertRaisesRegex(ValueError, "Unit changed"):
            perf.aggregate(runs)


class Compare(unittest.TestCase):
    def test_range_band_strict_threshold_and_direction(self):
        base = report([1, 2, 3, 4, 5])
        in_band = report([5, 6, 7, 8, 9])
        slower = report([6, 7, 8, 9, 10])
        self.assertFalse(any(x["regression"] for x in perf.compare_reports(base, in_band)))
        self.assertTrue(all(x["regression"] and x["noise_band"] == 4 for x in perf.compare_reports(base, slower)))
        self.assertFalse(any(x["regression"] for x in perf.compare_reports(slower, base)))

    def test_noisy_candidate_uses_larger_range(self):
        base = report([1, 2, 3, 4, 5])
        after = report([1, 13, 14, 15, 42])
        self.assertTrue(all(x["noise_band"] == 41 and not x["regression"] for x in perf.compare_reports(base, after)))

    def test_differing_environment_is_not_comparable(self):
        base = report([1, 2, 3, 4, 5])
        after = {**base, "environment": "another runtime"}
        with self.assertRaisesRegex(ValueError, "Incompatible reports"):
            perf.compare_reports(base, after)

    def test_compare_uses_raw_runs_not_stale_summary(self):
        base = {**report([1, 2, 3, 4, 5]), "probes": {"doc_open_long": {"median": 1000}}}
        after = report([1, 2, 3, 4, 5])
        self.assertTrue(all(x["delta"] == 0 for x in perf.compare_reports(base, after)))


class Collection(unittest.TestCase):
    def test_native_metrics_select_by_test_url_and_force_required_ratio(self):
        def result(name, metric, label, unit, value):
            return {"testIdentifier": "LAAPerformanceUITests/" + name + "()",
                    "testIdentifierURL": "test://com.apple.xcode/Conduit/" + perf.TEST_CLASS + "/" + name,
                    "testRuns": [{"metrics": [{"identifier": metric, "displayName": label,
                                              "unitOfMeasurement": unit, "measurements": [value]}]}]}
        cold = result("testColdLaunch", "com.apple.dt.XCTMetric_ApplicationLaunch-ApplicationFirstFramePresentationResponsive.duration",
                      "Duration (ApplicationFirstFramePresentationResponsive)", "s", 1.5)
        chat = result("testScrollChat", "synthetic.hitch.ratio", "Hitch Time Ratio", "ms/s", 3)
        work = result("testScrollWork", "synthetic.hitch.ratio", "Hitch Time Ratio", "ms/s", 0)
        duration = result("testScrollWork", "synthetic.duration", "Duration", "s", 1)
        samples = perf.parsed_native_metrics([cold, chat, work, duration])
        self.assertEqual({name: row["value"] for name, row in samples.items()}, {
            "cold_launch_first_usable": 1500, "chat_scroll_hitch_ratio": 3, "work_scroll_hitch_ratio": 0})
        with self.assertRaisesRegex(ValueError, "hitch-ratio measurement for testScrollWork"):
            perf.parsed_native_metrics([cold, chat, duration])

    def test_duplicate_and_missing_wall_markers_fail(self):
        def line(probe):
            return "prefix LAA_LAB_PERF " + json.dumps({"probe": probe, "ms": 6})
        log = "\n".join(line(probe) for probe in perf.WALL)
        self.assertEqual(perf.timing_log(log)["doc_open_long"]["value"], 6)
        with self.assertRaisesRegex(ValueError, "Duplicate timing"):
            perf.timing_log(log + "\n" + line("doc_open_long"))
        with self.assertRaisesRegex(ValueError, "Missing or unexpected"):
            perf.timing_log(line("doc_open_long"))

    def test_fixture_env_does_not_inherit_production_opt_ins(self):
        with patch.dict(perf.os.environ, {"LAA_UI_TEST_REAL_BRIDGE": "1", "LAA_BRIDGE_DEFAULT_ADDRESS": "https://production.invalid",
                                         "TEST_RUNNER_LAA_PERF_RUN": "1"}):
            self.assertFalse({"LAA_UI_TEST_REAL_BRIDGE", "LAA_BRIDGE_DEFAULT_ADDRESS", "TEST_RUNNER_LAA_PERF_RUN"} & perf.lab_env().keys())

    def test_quiet_gate_waits_until_xcode_sim_and_load_clear(self):
        readings = [{"load1": 1, "other_simulators": 1, "other_xcodebuild": 0},
                    {"load1": 1, "other_simulators": 0, "other_xcodebuild": 1},
                    {"load1": perf.LOAD_LIMIT + 1, "other_simulators": 0, "other_xcodebuild": 0},
                    {"load1": perf.LOAD_LIMIT, "other_simulators": 0, "other_xcodebuild": 0}]
        with patch.object(perf, "busy_snapshot", side_effect=readings), patch.object(perf.time, "sleep", return_value=None):
            self.assertEqual(perf.wait_quiet("phone", float("inf")), (True, readings))
        with patch.object(perf, "busy_snapshot", return_value=readings[0]):
            self.assertEqual(perf.wait_quiet("phone", 0), (False, readings[:1]))


if __name__ == "__main__":
    unittest.main()
