#!/usr/bin/env python3
"""Run or compare quiet LAA iPhone performance probes with synthetic inputs."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
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
import time
import urllib.request
import uuid

from suite import DEVELOPER_DIR, REPO, SLOT
from watch import DERIVED, PHONE_APP, PHONE_NAME, boot_devices, capture, log_json, named_device, simulator_inventory, test_states, xcode_base

SCHEME = "ConduitPerfLab"
SETTINGS = ("SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=incremental",
            "GCC_OPTIMIZATION_LEVEL=2", "CONDUIT_DEFAULT_RELAY_URL=http://127.0.0.1:9")
CONFIG = {"configuration": "Debug", "settings": list(SETTINGS), "spec": "project-laa.yml (UI-only lab scheme)"}
TEST_CLASS = "ConduitUITests/LAAPerformanceUITests"
TESTS = ("testColdLaunch", "testNavigationAndOpen", "testScrollChat", "testScrollWork")
DEST = ("chat", "work", "today", "doc", "usage")
WALL = {"warm_activate", "doc_open_long", "work_open_long_history"} | {
    f"nav_{source}_to_{target}" for source in DEST for target in DEST if source != target}
REQUIRED = WALL | {"cold_launch_first_usable", "chat_scroll_hitch_ratio", "work_scroll_hitch_ratio"}
LOAD_LIMIT = min(6.0, (os.cpu_count() or 2) / 2)
NOISE_RULE = "regression if new median minus baseline median exceeds max(baseline range, new range)"
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
    keys = quiet[0]["probes"].keys()
    if not REQUIRED.issubset(keys):
        raise ValueError(f"Missing required probes: {sorted(REQUIRED - keys)}")
    if any(run["probes"].keys() != keys for run in quiet):
        raise ValueError("Probe set changed between quiet runs")
    summary = {}
    for key in sorted(keys):
        entries = [run["probes"][key] for run in quiet]
        unit = entries[0]["unit"]
        if any(entry["unit"] != unit for entry in entries):
            raise ValueError(f"Unit changed: {key}")
        summary[key] = {"unit": unit, **stats([entry["value"] for entry in entries])}
    return summary


def compare_reports(before, after):
    fields = ("schema", "protocol", "configuration", "environment")
    if any(key not in before or key not in after or before[key] != after[key] for key in fields):
        raise ValueError("Incompatible reports (protocol, build settings, device/runtime, Xcode or quiet threshold)")
    old, new = aggregate(before["runs"]), aggregate(after["runs"])
    if old.keys() != new.keys():
        raise ValueError("Probe sets differ")
    changes = []
    for probe, a in old.items():
        b = new[probe]
        if a["unit"] != b["unit"]:
            raise ValueError(f"Incompatible unit: {probe}")
        band = max(a["spread"], b["spread"])
        delta = b["median"] - a["median"]
        changes.append({"probe": probe, "unit": a["unit"], "baseline": a["median"], "new": b["median"],
                        "delta": delta, "noise_band": band, "regression": delta > band})
    return changes


def lab_env(**extra):
    # Do not inherit Bridge/Hermes/fixture overrides or opt-ins from the caller.
    keys = ("PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LAA_BUILD_SLOT_HELD", "LAA_BUILD_SLOT_MAX_WAIT")
    return {**{k: os.environ[k] for k in keys if k in os.environ}, "DEVELOPER_DIR": DEVELOPER_DIR, **extra}


def log_run(cmd, log, timeout=300, extra=None, check=True):
    with log.open("a") as f:
        print("$ " + " ".join(map(str, cmd)), file=f, flush=True)
        return subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=REPO,
                              env=lab_env(**(extra or {})), check=check, timeout=timeout).returncode


def busy_snapshot(udid, allowed_pid=None):
    found = subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True, text=True, timeout=10)
    if found.returncode not in (0, 1):
        raise RuntimeError("Unable to check xcodebuild processes")
    others = sorted(int(p) for p in found.stdout.split() if int(p) != allowed_pid)
    sims = [d["name"] for group in simulator_inventory().values() for d in group
            if d["state"] != "Shutdown" and d["udid"] != udid]
    return {"at": utc(), "load1": round(os.getloadavg()[0], 3), "other_xcodebuild": others, "other_simulators": sorted(sims)}


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
    if samples.keys() != WALL:
        raise ValueError(f"Missing or unexpected wall probes: {sorted(samples.keys() ^ WALL)}")
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
    samples = {}
    for test, probe in (("testColdLaunch", "cold_launch_first_usable"), ("testScrollChat", "chat_scroll"),
                        ("testScrollWork", "work_scroll")):
        data = json.loads(capture("xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", str(bundle),
                                  "--test-id", f"LAAPerformanceUITests/{test}"))
        log_json(out / f"{test}.metrics.json", data)
        rows = list(metric_rows(data))
        matches = []
        for row in rows:
            name = (row["identifier"] + " " + row.get("displayName", "")).lower()
            key = re.sub(r"[^a-z0-9]", "", name)
            if probe.startswith("cold_") and "duration" in key:
                # The selected XCTest metric is the responsive app-launch
                # interval. Convert the exported seconds to the wall unit.
                matches.append(row)
            elif not probe.startswith("cold_") and "hitch" in key and "ratio" in key:
                matches.append(row)
        if len(matches) != 1 or len(matches[0]["measurements"]) != 1:
            raise ValueError(f"Expected one measurement for {test}; see {out / (test + '.metrics.json')}")
        row = matches[0]
        unit, value = row["unitOfMeasurement"], row["measurements"][0]
        if probe.startswith("cold_"):
            if unit in ("s", "seconds", "sec"): value *= 1000
            elif unit != "ms": raise ValueError(f"Unknown launch unit: {unit}")
            samples[probe] = {"unit": "ms", "value": value}
        else:
            samples[probe + "_hitch_ratio"] = {"unit": unit, "value": value}
    return samples


def prepare_build(out, phone, head, reuse):
    product = DERIVED / "Build/Products"
    stamp = DERIVED / "perf-build.json"
    signature = {"sha": head, "configuration": CONFIG, "runtime": phone["runtime"],
                 "xcode": capture("xcodebuild", "-version")}
    if reuse:
        if not stamp.exists() or json.loads(stamp.read_text()) != signature:
            raise RuntimeError("--reuse-build needs a prior build of the exact same SHA/settings/runtime")
    else:
        DERIVED.mkdir(parents=True, exist_ok=True)
        stamp.unlink(missing_ok=True)
        spec = DERIVED / "perf-project.yml"
        spec.write_text("""include:
  - path: ../project-laa.yml
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
        log_run(["xcodegen", "generate", "--spec", str(spec), "--project", str(REPO)], out / "build.log")
        cmd = xcode_base(SCHEME, "iOS", phone["udid"], DERIVED)
        log_run([*cmd, *SETTINGS, "build-for-testing"], out / "build.log", timeout=1800)
        log_json(stamp, signature)
    matches = list(product.glob(f"{SCHEME}*.xctestrun"))
    if len(matches) != 1:
        raise RuntimeError(f"Missing or ambiguous {SCHEME} .xctestrun")
    return matches[0], signature


def clear_credentials(udid, namespace, log):
    log_run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, PHONE_APP,
             "-laa-tab", "work", "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-no-vault-fixture",
             "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://perf-lab.invalid"], log, timeout=30,
            extra={"SIMCTL_CHILD_LAA_PERF_KEYCHAIN_NAMESPACE": namespace, "SIMCTL_CHILD_LAA_PERF_CLEAR_KEYCHAIN": "1",
                   "SIMCTL_CHILD_LAA_BRIDGE_DEFAULT_ADDRESS": "http://127.0.0.1:9"})
    # The app reads and clears its own synthetic namespace after its root is mounted.
    time.sleep(3)


def report_md(report):
    rows = ["# LAA Performance", "", f"Build `{report['sha']}` · {report['environment']['device']} · "
            f"{report['environment']['runtime']} · {report['configuration']['configuration']} + Swift `-O`", "",
            "| Probe | Unit | Quiet n | Median | Min | Max | Spread |", "|---|---|---:|---:|---:|---:|---:|"]
    for probe, row in report["probes"].items():
        values = " | ".join(f"{row[key]:.3f}" for key in ("median", "min", "max", "spread"))
        rows.append(f"| {probe} | {row['unit']} | {row['count']} | {values} |")
    return "\n".join(rows) + "\n"


def run_locked(args):
    started = time.monotonic()
    out = args.out
    head = capture("git", "rev-parse", "HEAD")
    if capture("git", "status", "--porcelain", "-uno"):
        raise RuntimeError("Commit source changes first so the recorded build SHA is exact")
    phone = named_device(PHONE_NAME)
    attempts = []
    with boot_devices((phone,), out / "simulator.log"):
        spec, build = prepare_build(out, phone, head, args.reuse_build)
        runtime = next(row for row in json.loads(capture("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
                       if row["identifier"] == phone["runtime"])
        namespace = str(uuid.uuid4()).upper()
        shared = ["xcodebuild", "test-without-building", "-xctestrun", str(spec), "-destination",
                  f"platform=iOS Simulator,id={phone['udid']}", "-jobs", "4", "-parallel-testing-enabled", "NO"]
        shared += [f"-only-testing:{TEST_CLASS}/{name}" for name in TESTS]
        accepted = 0
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
                    tick = time.monotonic()
                    rc, interference = measured_test([*shared, "-resultBundlePath", str(bundle)], run_out / "test.log", phone["udid"], extra)
                    row.update(exit=rc, after=busy_snapshot(phone["udid"]), interference=interference,
                               wall_seconds=round(time.monotonic() - tick, 2))
                    if interference or row["after"]["other_xcodebuild"] or row["after"]["other_simulators"]:
                        row["state"] = "noisy"
                        log_json(out / "attempts.json", attempts)
                        if bundle.exists(): shutil.rmtree(bundle)
                        continue
                    row["state"] = "invalid"
                    test_results = test_states(bundle) if bundle.exists() else {}
                    log_json(run_out / "tests.json", test_results)
                    log_json(out / "attempts.json", attempts)
                    if rc or test_results.keys() != {f"{TEST_CLASS}/{t}" for t in TESTS} or any(
                            test["result"] != "Passed" for test in test_results.values()):
                        raise RuntimeError(f"Performance test failed, skipped or was not executed ({rc}): {run_out / 'test.log'}")
                    row["probes"] = {**timing_log((run_out / "test.log").read_text()), **native_metrics(bundle, run_out)}
                    row["state"] = "quiet"
                    log_json(out / "attempts.json", attempts)
                    shutil.rmtree(bundle)
                    accepted += 1
                    print(f"Quiet run {accepted}/{args.runs} (load {row['before']['load1']}, {row['wall_seconds']}s)", flush=True)
                    if accepted == args.runs:
                        break
            finally:
                clear_credentials(phone["udid"], namespace, out / "simulator.log")
    if accepted != args.runs:
        raise RuntimeError(f"Insufficient quiet runs: {accepted}/{args.runs}; see {out / 'attempts.json'}")
    result = {"schema": 1, "protocol": "laa-simulator-perf-v1", "sha": head, "configuration": CONFIG,
              "environment": {"device": phone["name"], "device_type": phone["deviceTypeIdentifier"],
                              "os": runtime["version"], "runtime": runtime["identifier"], "runtime_build": runtime["buildversion"],
                              "xcode": build["xcode"], "quiet_max_load1": LOAD_LIMIT}, "udid": phone["udid"],
              "completed_at": utc(), "wall_seconds": round(time.monotonic() - started, 2), "noise_rule": NOISE_RULE,
              "runs": attempts, "probes": aggregate(attempts)}
    log_json(out / "perf.json", result)
    (out / "perf.md").write_text(report_md(result))
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
            print(f"{'REGRESSION' if row['regression'] else 'within band'} {row['probe']}: "
                  f"{row['baseline']:.3f} → {row['new']:.3f} {row['unit']} "
                  f"({row['delta']:+.3f}, band {row['noise_band']:.3f})")
        return int(any(row["regression"] for row in changes))
    if not MIN_RUNS <= args.runs <= 50:
        parser.error(f"--runs must be between {MIN_RUNS} and 50")
    args.out = args.out.resolve()
    if os.environ.get("LAA_BUILD_SLOT_HELD") != "1":
        args.out.mkdir(parents=True, exist_ok=True)
        return subprocess.run(["/bin/bash", SLOT, sys.executable, str(Path(__file__).resolve()), "run",
                               "--out", str(args.out), "--runs", str(args.runs)] + (["--reuse-build"] if args.reuse_build else []),
                              cwd=REPO, env=lab_env()).returncode
    if (args.out / "attempts.json").exists() or (args.out / "perf.json").exists():
        raise RuntimeError("Choose a new output directory; prior measurements are evidence")
    return run_locked(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
