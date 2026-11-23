#!/usr/bin/env python3
"""Run or compare quiet LAA iPhone performance probes with synthetic inputs."""
import argparse
from contextlib import contextmanager
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

import perf_frames
from suite import REPO, SLOT
from watch import (DERIVED, PHONE_APP, PHONE_NAME, boot_devices, capture, lab_env, log_json,
                   named_device, require_build_headroom, simulator_inventory, test_states, xcode_base)

SCHEME = "ConduitPerfLab"
SETTINGS = ("SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=incremental",
            "GCC_OPTIMIZATION_LEVEL=2", "CONDUIT_DEFAULT_RELAY_URL=http://127.0.0.1:9")
CONFIG = {"configuration": "Debug", "settings": list(SETTINGS), "spec": "project-laa.yml (UI-only lab scheme)"}
TEST_CLASS = "ConduitUITests/LAAPerformanceUITests"
TESTS = ("testColdLaunch", "testNavigationAndOpen", "testScrollChat", "testScrollWork")
DEST = ("chat", "work", "today", "doc", "usage")
WALL = {"warm_activate", "doc_open_long", "work_open_long_history"} | {
    f"nav_{source}_to_{target}" for source in DEST for target in DEST if source != target}
NATIVE = {"cold_launch_first_usable"} | {f"{kind}_scroll_{metric}" for kind in perf_frames.KINDS
                                         for metric in ("hitch_ratio", "signpost_duration")}
PROBES = WALL | NATIVE | perf_frames.PROBES
BASELINE = Path(__file__).with_name("perf-baseline.json")
PROTOCOL = "laa-simulator-perf-v2"
LOAD_LIMIT = min(6.0, (os.cpu_count() or 2) / 2)
NOISE_RULE = "regression if worsening median delta exceeds max(baseline range, new range); observed Hz prefers higher, expected Hz is context"
MIN_RUNS = 5


def utc():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def stats(values):
    """Raise instead of silently omitting a probe or accepting invalid samples."""
    if len(values) < MIN_RUNS or any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 for v in values):
        raise ValueError(f"Need at least {MIN_RUNS} finite, nonnegative samples")
    lo, hi = min(values), max(values)
    return {"count": len(values), "median": statistics.median(values), "min": lo, "max": hi,
            "spread": hi - lo, "samples": list(values)}


def aggregate(runs):
    quiet = [run for run in runs if run.get("state") == "quiet"]
    if len(quiet) < MIN_RUNS:
        raise ValueError(f"Only {len(quiet)} quiet runs")
    summary = {}
    for key in sorted(PROBES):
        entries = [run["probes"][key] for run in quiet if key in run["probes"]]
        signatures = {(entry["unit"], entry.get("source")) for entry in entries}
        if len(entries) < MIN_RUNS:
            reasons = Counter(run.get("unavailable", {}).get(key, "No sample emitted") for run in quiet if key not in run["probes"])
            why = "; ".join(f"{reason} ({n})" for reason, n in sorted(reasons.items()))
            summary[key] = {"state": "unavailable", "count": len(entries), "reason": f"Need {MIN_RUNS} samples: {why}"}
        elif len(signatures) != 1:
            summary[key] = {"state": "unavailable", "count": len(entries), "reason": "Unit or metric source changed within series"}
        else:
            unit, source = signatures.pop()
            summary[key] = {"state": "measured", "unit": unit, **({"source": source} if source else {}),
                            **stats([entry["value"] for entry in entries])}
    return summary


def lost_probes(before, after):
    return [key for key, row in before.items() if row["state"] == "measured" and after[key]["state"] != "measured"]


def compare_reports(before, after):
    fields = ("schema", "protocol", "configuration", "environment")
    if any(key not in before or key not in after or before[key] != after[key] for key in fields):
        raise ValueError("Incompatible reports (protocol, build settings, device/runtime, Xcode or quiet threshold)")
    old, new = aggregate(before["runs"]), aggregate(after["runs"])
    changes = []
    for probe, a in old.items():
        b = new[probe]
        if a["state"] != "measured" or b["state"] != "measured":
            reason = "; ".join(f"{side}: {row['reason']}" for side, row in (("baseline", a), ("new", b))
                               if row["state"] != "measured")
        elif a["unit"] != b["unit"] or a.get("source") != b.get("source"):
            reason = "Unit or metric source differs"
        else:
            band = max(a["spread"], b["spread"])
            delta = b["median"] - a["median"]
            # Nominal refresh is context, whereas a lower observed callback
            # cadence is worse. All time/count probes prefer smaller values.
            context = probe.endswith("_expected_hz")
            worse = -delta if probe.endswith("_observed_hz") else delta
            changes.append({"probe": probe, "state": "context" if context else "comparable", "unit": a["unit"],
                            "baseline": a["median"], "new": b["median"], "delta": delta, "noise_band": band,
                            "regression": not context and worse > band})
            continue
        changes.append({"probe": probe, "state": "not_comparable", "reason": reason,
                        "lost": a["state"] == "measured" and b["state"] != "measured"})
    return changes


def log_run(cmd, log, timeout=300, extra=None, check=True):
    with log.open("a") as f:
        print("$ " + " ".join(map(str, cmd)), file=f, flush=True)
        return subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=REPO,
                              env=lab_env(**(extra or {})), check=check, timeout=timeout).returncode


def busy_snapshot(udid, allowed_pid=None):
    found = subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True, text=True, timeout=10)
    if found.returncode not in (0, 1):
        raise RuntimeError("Unable to check xcodebuild processes")
    others = sum(int(p) != allowed_pid for p in found.stdout.split())
    sims = sum(d["state"] != "Shutdown" and d["udid"] != udid
               for group in simulator_inventory().values() for d in group)
    return {"at": utc(), "load1": round(os.getloadavg()[0], 3), "other_xcodebuild": others, "other_simulators": sims}


def wait_quiet(udid, deadline):
    observations = []
    while True:
        row = busy_snapshot(udid)
        observations.append(row)
        if row["load1"] <= LOAD_LIMIT and not row["other_xcodebuild"] and not row["other_simulators"]:
            return True, observations
        if time.monotonic() >= deadline:
            return False, observations
        time.sleep(5)


def measured_test(cmd, log, udid, extra):
    other_work = []
    with log.open("w") as f:
        print("$ " + " ".join(map(str, cmd)), file=f, flush=True)
        with subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=REPO, env=lab_env(**extra)) as proc:
            try:
                deadline = time.monotonic() + 480
                while proc.poll() is None and time.monotonic() < deadline:
                    row = busy_snapshot(udid, proc.pid)
                    if row["other_xcodebuild"] or row["other_simulators"]:
                        other_work.append(row)
                    time.sleep(5)
                rc = proc.wait(timeout=1)
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=30)
    return rc, other_work


@contextmanager
def work_fixture(out):
    # Claim a currently free adjacent pair: the API and test-only reset port.
    for port in range(19720, 19770, 2):
        try:
            with socket.socket() as api, socket.socket() as control:
                api.bind(("127.0.0.1", port))
                control.bind(("127.0.0.1", port + 1))
            break
        except OSError:
            continue
    else:
        raise RuntimeError("No adjacent ports available for the loopback fixture")
    with (out / "fixture.log").open("w") as f:
        cmd = ["node", "scripts/laa/work-ui-fixture.mjs"]
        proc = subprocess.Popen(cmd, cwd=REPO, env=lab_env(WORK_FIXTURE_PORT=str(port)),
                                stdout=f, stderr=subprocess.STDOUT)
        try:
            for _ in range(40):
                if proc.poll() is not None:
                    raise RuntimeError("Work fixture exited at startup; see fixture.log")
                try:
                    reset_fixture(port)
                    break
                except OSError:
                    time.sleep(.25)
            else:
                raise RuntimeError("Work fixture did not become ready")
            yield port
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()


def reset_fixture(port):
    # Explicit proxy exclusion. Only synthetic generated counts are read.
    local = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with local.open(f"http://127.0.0.1:{port + 1}/reset", timeout=3) as r:
        data = json.load(r)
    if data.get("messages") != 63 or data.get("served") != 0:
        raise RuntimeError("Work fixture reset returned the wrong dataset")


def timing_log(text):
    samples = {}
    for line in text.splitlines():
        if "LAA_LAB_PERF {" not in line:
            continue
        obj, _ = json.JSONDecoder().raw_decode(line.split("LAA_LAB_PERF ", 1)[1])
        probe = obj["probe"]
        if probe in samples:
            raise ValueError(f"Duplicate timing: {probe}")
        samples[probe] = {"unit": "ms", "value": obj["ms"]}
    if samples.keys() - WALL:
        raise ValueError(f"Unexpected wall probes: {sorted(samples.keys() - WALL)}")
    return samples


def metric_rows(value):
    if isinstance(value, dict):
        if {"identifier", "measurements", "unitOfMeasurement"}.issubset(value):
            yield value
        else:
            for val in value.values():
                yield from metric_rows(val)
    elif isinstance(value, list):
        for val in value:
            yield from metric_rows(val)


def native_metrics(bundle, out):
    # The xcresult identifiers include `()` and are not the `-only-testing`
    # selectors. Read the real identifiers and metrics in one call.
    data = json.loads(capture("xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", str(bundle)))
    log_json(out / "metrics.json", data)
    return parsed_native_metrics(data)


def parsed_native_metrics(data):
    samples, unavailable = {}, {}
    by_test = {test: [metric for result in data if result["testIdentifierURL"].endswith(f"/{TEST_CLASS}/{test}")
                      for metric in metric_rows(result)] for test in TESTS}

    def store(test, probe, rows, duration=False):
        if len(rows) != 1 or len(rows[0]["measurements"]) != 1:
            observed = ", ".join(sorted({row.get("displayName", row["identifier"]) for row in by_test[test]})) or "none"
            unavailable[probe] = f"XCTest did not export a single matching sample; exported: {observed}"
            return
        row = rows[0]
        unit, value = row["unitOfMeasurement"], row["measurements"][0]
        if duration:
            if unit in ("s", "seconds", "sec"):
                unit, value = "ms", 1000 * value
            elif unit != "ms":
                unavailable[probe] = f"Unknown XCTest duration unit: {unit}"
                return
        samples[probe] = {"unit": unit, "value": value, "source": row["identifier"]}

    launch = "testColdLaunch"
    store(launch, "cold_launch_first_usable", [r for r in by_test[launch]
          if r["identifier"].endswith("-ApplicationFirstFramePresentationResponsive.duration")], duration=True)
    for kind in perf_frames.KINDS:
        test = f"testScroll{kind.capitalize()}"
        rows = by_test[test]
        store(test, f"{kind}_scroll_signpost_duration", [r for r in rows
              if r["identifier"].endswith("-Scroll_DraggingAndDeceleration.duration")], duration=True)
        ratios = []
        for row in rows:
            key = re.sub(r"[^a-z0-9]", "", (row["identifier"] + " " + row.get("displayName", "")).lower())
            if "hitch" in key and "ratio" in key:
                ratios.append(row)
        signpost = [row for row in ratios if "XCTMetric_OSSignpost" in row["identifier"]]
        store(test, f"{kind}_scroll_hitch_ratio", signpost or ratios)
    return samples, unavailable


def prepare_build(out, phone, head, reuse):
    product = DERIVED / "Build/Products"
    stamp = DERIVED / "perf-build.json"
    signature = {"sha": head, "configuration": CONFIG, "runtime": phone["runtime"],
                 "xcode": capture("xcodebuild", "-version")}
    if not reuse:
        require_build_headroom()
        DERIVED.mkdir(parents=True, exist_ok=True)
        stamp.unlink(missing_ok=True)
        # A root-relative spec preserves XcodeGen's folder reference paths.
        with tempfile.NamedTemporaryFile(mode="w", dir=REPO, prefix=".lab-perf-", suffix=".yml") as spec:
            spec.write("""include:
  - path: project-laa.yml
schemes:
  ConduitPerfLab:
    build:
      targets:
        Conduit: all
        ConduitUITests: [test]
    test:
      config: Debug
      targets:
        - name: ConduitUITests
          parallelizable: false
targets:
  ConduitUITests:
    sources:REPLACE:
      - path: ConduitUITests/LAAPerformanceUITests.swift
""")
            spec.flush()
            log_run(["xcodegen", "generate", "--spec", spec.name], out / "build.log")
        cmd = xcode_base(SCHEME, "iOS", phone["udid"], DERIVED)
        log_run([*cmd, *SETTINGS, "build-for-testing"], out / "build.log", timeout=1800)
    matches = list(product.glob(f"{SCHEME}*.xctestrun"))
    if len(matches) != 1:
        raise RuntimeError(f"Missing or ambiguous {SCHEME} .xctestrun")
    debug = product / "Debug-iphonesimulator"
    app = debug / "Conduit.app"
    binaries = [app / "Conduit", *sorted(app.glob("*.debug.dylib")),
                debug / "ConduitUITests-Runner.app/PlugIns/ConduitUITests.xctest/ConduitUITests", matches[0]]
    signature["build_products"] = {}
    for path in binaries:
        digest = hashlib.sha256()
        with path.open("rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                digest.update(block)
        signature["build_products"][path.name] = digest.hexdigest()
    if reuse:
        if not stamp.exists() or json.loads(stamp.read_text()) != signature:
            raise RuntimeError("--reuse-build needs the exact same build SHA/settings/runtime and binaries")
    else:
        log_json(stamp, signature)
    return matches[0], signature


def clear_credentials(udid, namespace, log):
    container = frame_container(udid)
    if not container:
        raise RuntimeError("Cannot verify perf Keychain cleanup: app container not found")
    receipt = Path(container) / "Library/Caches" / f"laa-perf-cleanup-{namespace}.txt"
    receipt.unlink(missing_ok=True)
    log_run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, PHONE_APP,
             "-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-no-vault-fixture",
             "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://perf-lab.invalid"], log, timeout=30,
            extra={"SIMCTL_CHILD_LAA_PERF_KEYCHAIN_NAMESPACE": namespace, "SIMCTL_CHILD_LAA_LAB_KEYCHAIN_NAMESPACE": namespace,
                   "SIMCTL_CHILD_LAA_PERF_CLEAR_KEYCHAIN": "1", "SIMCTL_CHILD_LAA_BRIDGE_DEFAULT_ADDRESS": "http://127.0.0.1:9"})
    deadline = time.monotonic() + 10
    while not receipt.is_file() and time.monotonic() < deadline:
        time.sleep(.25)
    if not receipt.is_file():
        raise RuntimeError("Perf Keychain cleanup not acknowledged by app")
    result = receipt.read_text().strip()
    receipt.unlink()
    with log.open("a") as f:
        print(f"Perf namespaced Keychain cleanup: {result}", file=f)
    if result not in ("deleted", "absent"):
        raise RuntimeError(f"Perf Keychain cleanup failed: {result}")


def frame_container(udid):
    try:
        return capture("xcrun", "simctl", "get_app_container", udid, PHONE_APP, "data", stderr=subprocess.DEVNULL)
    except subprocess.SubprocessError:
        return None


def collect_probes(bundle, out, udid, trial):
    text = (out / "test.log").read_text()
    samples = timing_log(text)
    unavailable = {key: "XCTest did not print the timed action marker" for key in WALL - samples.keys()}
    try:
        native, why = native_metrics(bundle, out)
    except (ValueError, KeyError, subprocess.SubprocessError):
        native, why = {}, dict.fromkeys(NATIVE, "xcresulttool did not return readable metric data")
    samples.update(native)
    unavailable.update(why)
    proxy, why = perf_frames.collect(text, trial, frame_container(udid), out)
    samples.update(proxy)
    unavailable.update(why)
    return samples, unavailable


def report_md(report):
    rows = ["# LAA Performance", "", f"Build `{report['sha']}` · {report['environment']['device']} · "
            f"{report['environment']['runtime']} · {report['configuration']['configuration']} + Swift `-O`", "",
            "Scroll `proxy` probes describe this Mac's Simulator callback timings, not physical-device frames.", "",
            "| Probe | Unit | Quiet n | Median | Min | Max | Spread |", "|---|---|---:|---:|---:|---:|---:|"]
    for probe, row in report["probes"].items():
        if row["state"] == "measured":
            values = " | ".join(f"{row[key]:.3f}" for key in ("median", "min", "max", "spread"))
            rows.append(f"| {probe} | {row['unit']} | {row['count']} | {values} |")
    missing = [f"- `{probe}`: {row['reason']}" for probe, row in report["probes"].items() if row["state"] == "unavailable"]
    if missing:
        rows.extend(["", "Unavailable (not comparable):", *missing])
    return "\n".join(rows) + "\n"


def run_locked(args):
    started = time.monotonic()
    out = args.out
    head = capture("git", "rev-parse", "HEAD")
    if capture("git", "status", "--porcelain", "-uno"):
        raise RuntimeError("Commit source changes first so the recorded build SHA is exact")
    baseline = json.loads(BASELINE.read_text()) if BASELINE.is_file() else None
    previous = aggregate(baseline["runs"]) if baseline and baseline.get("protocol") == PROTOCOL else {}
    phone = named_device(PHONE_NAME)
    attempts = []
    counts = Counter()
    with boot_devices((phone,), out / "simulator.log", shutdown_wait=30):
        spec, build = prepare_build(out, phone, head, args.reuse_build)
        runtime = next(row for row in json.loads(capture("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
                       if row["identifier"] == phone["runtime"])
        namespace = str(uuid.uuid4()).upper()
        shared = ["xcodebuild", "test-without-building", "-xctestrun", str(spec), "-destination",
                  f"platform=iOS Simulator,id={phone['udid']}", "-jobs", "4", "-parallel-testing-enabled", "NO"]
        shared += [f"-only-testing:{TEST_CLASS}/{name}" for name in TESTS]
        accepted = 0
        launched = False
        with work_fixture(out) as port:
            extra = {"TEST_RUNNER_LAA_PERF_RUN": "1", "TEST_RUNNER_LAA_PERF_NAMESPACE": namespace,
                     "TEST_RUNNER_LAA_PERF_PORT": str(port)}
            try:
                for number in range(1, args.runs + 5):
                    run_out = out / f"run-{number:02}"
                    run_out.mkdir(exist_ok=False)
                    reset_fixture(port)
                    quiet, observations = wait_quiet(phone["udid"], time.monotonic() + 120)
                    row = {"attempt": number, "before": observations[-1], "wait_observations": observations}
                    attempts.append(row)
                    if not quiet:
                        row["state"] = "noisy"
                        log_json(out / "attempts.json", attempts)
                        continue
                    bundle = run_out / "perf.xcresult"
                    trial = str(uuid.uuid4()).upper()
                    tick = time.monotonic()
                    launched = True
                    rc, interference = measured_test([*shared, "-resultBundlePath", str(bundle)], run_out / "test.log", phone["udid"],
                                                      {**extra, "TEST_RUNNER_LAA_PERF_FRAME_TRIAL": trial})
                    row.update(exit=rc, after=busy_snapshot(phone["udid"]), interference=interference,
                               wall_seconds=round(time.monotonic() - tick, 2))
                    if interference or row["after"]["other_xcodebuild"] or row["after"]["other_simulators"]:
                        row["state"] = "noisy"
                        log_json(out / "attempts.json", attempts)
                        perf_frames.cleanup(trial, frame_container(phone["udid"]))
                        if bundle.exists(): shutil.rmtree(bundle)
                        continue
                    row["state"] = "invalid"
                    test_results = test_states(bundle) if bundle.exists() else {}
                    log_json(run_out / "tests.json", test_results)
                    log_json(out / "attempts.json", attempts)
                    if rc or test_results.keys() != {f"{TEST_CLASS}/{t}" for t in TESTS} or any(
                            test["result"] != "Passed" for test in test_results.values()):
                        print(f"Invalid trial {number}: test failed, skipped or not executed ({rc}); see {run_out / 'test.log'}", flush=True)
                        perf_frames.cleanup(trial, frame_container(phone["udid"]))
                        continue
                    row["probes"], row["unavailable"] = collect_probes(bundle, run_out, phone["udid"], trial)
                    row["state"] = "quiet"
                    log_json(out / "attempts.json", attempts)
                    shutil.rmtree(bundle)
                    accepted += 1
                    counts.update(row["probes"].keys())
                    print(f"Quiet run {accepted}/{args.runs} (load {row['before']['load1']}, {row['wall_seconds']}s, "
                          f"{len(row['probes'])} probes)", flush=True)
                    needs_retry = any(0 < counts[key] < MIN_RUNS or
                                      (previous.get(key, {}).get("state") == "measured" and counts[key] < MIN_RUNS) for key in PROBES)
                    if accepted >= args.runs and not needs_retry:
                        break
            finally:
                if launched:
                    clear_credentials(phone["udid"], namespace, out / "simulator.log")
    if accepted < args.runs:
        raise RuntimeError(f"Insufficient quiet runs: {accepted}/{args.runs}; see {out / 'attempts.json'}")
    result = {"schema": 2, "protocol": PROTOCOL, "sha": head, "configuration": CONFIG,
              "environment": {"device": phone["name"], "device_type": phone["deviceTypeIdentifier"],
                              "os": runtime["version"], "runtime": runtime["identifier"], "runtime_build": runtime["buildversion"],
                              "xcode": build["xcode"], "quiet_max_load1": LOAD_LIMIT},
              "build_products": build["build_products"], "completed_at": utc(),
              "wall_seconds": round(time.monotonic() - started, 2), "noise_rule": NOISE_RULE,
              "frame_proxy": perf_frames.METHOD, "runs": attempts, "probes": aggregate(attempts)}
    lost = lost_probes(previous, result["probes"])
    result["lost_baseline_probes"] = lost
    log_json(out / "perf.json", result)
    (out / "perf.md").write_text(report_md(result))
    if lost:
        raise RuntimeError(f"Previously measured probes now unavailable: {lost}; see {out / 'perf.json'}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--out", type=Path, required=True)
    run.add_argument("--runs", type=int, default=MIN_RUNS)
    run.add_argument("--reuse-build", action="store_true", help="Reuse only an exact build of this SHA and SDK")
    cmp = sub.add_parser("compare")
    cmp.add_argument("baseline", type=Path)
    cmp.add_argument("new", type=Path)
    args = parser.parse_args()
    if args.command == "compare":
        changes = compare_reports(json.loads(args.baseline.read_text()), json.loads(args.new.read_text()))
        print(NOISE_RULE)
        for row in changes:
            if row["state"] == "not_comparable":
                print(f"NOT COMPARABLE {row['probe']}: {row['reason']}")
                continue
            label = "context" if row["state"] == "context" else "REGRESSION" if row["regression"] else "within band"
            print(f"{label} {row['probe']}: {row['baseline']:.3f} → {row['new']:.3f} {row['unit']} "
                  f"({row['delta']:+.3f}, band {row['noise_band']:.3f})")
        compared = sum(row["state"] == "comparable" for row in changes)
        unavailable = sum(row["state"] == "not_comparable" for row in changes)
        print(f"Compared: {compared}; not comparable: {unavailable}")
        if any(row.get("regression") or row.get("lost") for row in changes):
            return 1
        return 0 if compared else 2
    if not MIN_RUNS <= args.runs <= 50:
        parser.error(f"--runs must be between {MIN_RUNS} and 50")
    args.out = args.out.resolve()
    if os.environ.get("LAA_BUILD_SLOT_HELD") != "1":
        args.out.mkdir(parents=True, exist_ok=True)
        # This wrapper starts only after lock_run hands over the slot. Log
        # local time before starting Python so it can be matched to the watcher.
        stamp = 'printf "PERF slot acquired: %s\\n" "$(/bin/date +%Y-%m-%dT%H:%M:%S%z)"; exec "$@"'
        return subprocess.run(["/bin/bash", SLOT, "/bin/bash", "-c", stamp, "perf-slot",
                               sys.executable, str(Path(__file__).resolve()), "run", "--out", str(args.out),
                               "--runs", str(args.runs)] + (["--reuse-build"] if args.reuse_build else []),
                              cwd=REPO, env=lab_env()).returncode
    if (args.out / "attempts.json").exists() or (args.out / "perf.json").exists():
        raise RuntimeError("Choose a new output directory; prior measurements are evidence")
    return run_locked(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
