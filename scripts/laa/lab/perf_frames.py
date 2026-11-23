"""Scroll window metrics for a simulator's CADisplayLink delivery, not presented frames."""
import json
import math
from pathlib import Path
import statistics

KINDS = ("chat", "work")
SOURCE = "cadisplaylink-simulator-proxy-v1"
METRICS = {"hitch_ratio": "ms/s", "late_1_5x": "frames", "late_2x": "frames", "worst_frame": "ms",
           "expected_hz": "Hz", "observed_hz": "Hz"}
PROBES = {f"{kind}_scroll_proxy_{metric}" for kind in KINDS for metric in METRICS}
METHOD = {"source": SOURCE, "scope": "Simulator main-run-loop display-link cadence; not presented frames or absolute device performance",
          "comparability": "Before/after only on the same Mac, simulator runtime and scripted protocol",
          "window": "Monotonic XCTest gesture/deceleration span; control taps and export excluded",
          "budget": "Previous callback targetTimestamp minus timestamp; no forced refresh rate",
          "hitch_ratio": "Sum of the portions of callback intervals after their expected deadline and inside the scroll window / window duration (ms/s)",
          "frame_counts": "Actual interval strictly greater than 1.5x or 2x expected; intervals ending in the window",
          "refresh": "Expected Hz = reciprocal of median budget, observed Hz = callbacks divided by their covered time"}


def number(x):
    if type(x) not in (int, float) or not math.isfinite(x):
        raise ValueError("non-finite value")
    return x


def summarize(trace, window):
    start, end = number(window["start"]), number(window["end"])
    if trace["overflow"] or not number(trace["started"]) <= start < end <= number(trace["stopped"]):
        raise ValueError("capture overflow or gesture window outside recording")
    if end - start < 0.1:
        raise ValueError("gesture window too short")
    intervals = [(number(row["end"]), number(row["actual"]), number(row["expected"])) for row in trace["intervals"]]
    if not intervals or intervals[0][0] - intervals[0][1] > start or intervals[-1][0] < end:
        raise ValueError("display-link intervals do not cover the gesture window")
    late_seconds = 0.0
    frames = []
    previous = None
    for stamp, actual, expected in intervals:
        origin = stamp - actual
        if actual <= 0 or expected <= 0 or (previous is not None and abs(origin - previous) > 0.000001):
            raise ValueError("discontinuous or invalid display-link intervals")
        previous = stamp
        late_seconds += max(0, min(stamp, end) - max(origin + expected, start))
        if start < stamp <= end:
            frames.append((actual, expected))
    if len(frames) < 2:
        raise ValueError("fewer than two display-link intervals in the gesture window")
    return {"hitch_ratio": 1000 * late_seconds / (end - start),
            "late_1_5x": sum(actual > 1.5 * expected for actual, expected in frames),
            "late_2x": sum(actual > 2 * expected for actual, expected in frames),
            "worst_frame": 1000 * max(actual for actual, _ in frames),
            "expected_hz": 1 / statistics.median(expected for _, expected in frames),
            "observed_hz": len(frames) / sum(actual for actual, _ in frames)}


def trace_path(container, trial, kind):
    return Path(container) / "Library/Caches" / f"laa-perf-frame-{trial}-{kind}.json"


def cleanup(trial, container):
    if container:
        for kind in KINDS:
            trace_path(container, trial, kind).unlink(missing_ok=True)


def collect(text, trial, container, out):
    windows = {}
    for line in text.splitlines():
        if "LAA_LAB_FRAME {" in line:
            item, _ = json.JSONDecoder().raw_decode(line.split("LAA_LAB_FRAME ", 1)[1])
            kind = item["kind"]
            if kind not in KINDS or kind in windows:
                raise ValueError(f"Unknown or duplicate frame window: {kind}")
            windows[kind] = item
    samples, unavailable = {}, {}
    for kind in KINDS:
        path = trace_path(container, trial, kind) if container else None
        try:
            if not path or not path.is_file() or kind not in windows:
                raise ValueError("App did not export a matching display-link trace and gesture window")
            trace = json.loads(path.read_text())
            (out / f"frames-{kind}.json").write_text(json.dumps({"window": windows[kind], "trace": trace}) + "\n")
            for name, value in summarize(trace, windows[kind]).items():
                samples[f"{kind}_scroll_proxy_{name}"] = {"unit": METRICS[name], "value": value, "source": SOURCE}
        except (ValueError, KeyError, OSError) as exc:
            unavailable.update({f"{kind}_scroll_proxy_{name}": str(exc) for name in METRICS})
        finally:
            if path:
                path.unlink(missing_ok=True)
    return samples, unavailable
