#!/usr/bin/env python3
"""Validate and test the named LAA Watch simulator pair, using synthetic data."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
import plistlib
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import uuid

from suite import DEVELOPER_DIR, REPO, SLOT, SIGNING, env, sh

PHONE_NAME = "LAA 16 Pro Max"
WATCH_NAME = "LAA Watch S11 46"
DERIVED = REPO / ".deriveddata-watch"
PHONE_APP = "com.laa-inc.laa"
WATCH_APP = PHONE_APP + ".watchkitapp"
VARIANTS = ("light", "dark", "long-ja-ax5")
WATCH_TEST = "ConduitWatchUITests/LAAWatchUITests"
WATCH_RUNNER = "com.laa-inc.laa.watchuitests.xctrunner"
AX5 = "accessibility-extra-extra-extra-large"


def lab_env(**extra):
    # Do not pass Bridge/Hermes endpoints, test opt-ins or auth to the slot.
    keys = ("PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LAA_BUILD_SLOT_HELD", "LAA_BUILD_SLOT_MAX_WAIT")
    return {**{k: os.environ[k] for k in keys if k in os.environ}, "DEVELOPER_DIR": DEVELOPER_DIR, **extra}


def capture(*cmd, timeout=60, stderr=None):
    return subprocess.check_output(cmd, cwd=REPO, env=lab_env(), text=True, timeout=timeout, stderr=stderr).strip()


def simulator_inventory():
    return json.loads(capture("xcrun", "simctl", "list", "devices", "--json"))["devices"]


def named_device(name, inventory=None):
    inventory = simulator_inventory() if inventory is None else inventory
    matches = [{**d, "runtime": runtime} for runtime, group in inventory.items()
               for d in group if d["name"] == name and d["isAvailable"]]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one available simulator named {name!r}, found {len(matches)}")
    return matches[0]


def pairs():
    return json.loads(capture("xcrun", "simctl", "list", "pairs", "--json"))["pairs"]


def named_pair(phone, watch):
    matches = [key for key, pair in pairs().items()
               if pair["phone"]["udid"] == phone["udid"] and pair["watch"]["udid"] == watch["udid"]]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one {PHONE_NAME} / {WATCH_NAME} pair; see LAB.md for recreation")
    return matches[0]


def log_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@contextmanager
def boot_devices(devices, log):
    owned = []
    try:
        deadline = time.monotonic() + 25
        while True:
            inventory = {d["udid"]: d["state"] for group in simulator_inventory().values() for d in group}
            busy = {d["name"]: inventory[d["udid"]] for d in devices if inventory[d["udid"]] != "Shutdown"}
            with log.open("a") as f:
                print(f"{now()} preflight: {busy or 'all requested simulators Shutdown'}", file=f)
            if not busy:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Simulator still busy {busy}; refusing to take over (see {log})")
            # A preceding slot may have requested an asynchronous shutdown.
            time.sleep(3)
        for device in devices:
            owned.append(device["udid"])
            rc = sh(["xcrun", "simctl", "boot", device["udid"]], log, timeout=60)
            if rc and named_device(device["name"])["state"] not in ("Booting", "Booted"):
                raise RuntimeError(f"Could not boot {device['name']}; see {log}")
        for udid in owned:
            sh(["xcrun", "simctl", "bootstatus", udid], log, check=True, timeout=300)
        yield
    finally:
        for udid in reversed(owned):
            sh(["xcrun", "simctl", "shutdown", udid], log, timeout=60)
        if owned:
            states = {d["udid"]: d["state"] for group in simulator_inventory().values() for d in group}
            if any(states.get(udid) != "Shutdown" for udid in owned):
                raise RuntimeError(f"Simulator shutdown not confirmed; see {log}")


def check_connected(pair_id, phone, watch, log):
    stop = time.monotonic() + 65
    state = None
    while time.monotonic() < stop:
        snapshot = pairs()[pair_id]
        state = snapshot["state"]
        if state == "(active, connected)" and all(snapshot[k]["state"] == "Booted" for k in ("phone", "watch")):
            msg = (f"{pair_id} {state}\n" + "\n".join(
                f"{d['name']}: {d['runtime'].split('.')[-1]} ({d['udid']})" for d in (phone, watch)))
            with log.open("a") as f:
                print(msg, file=f)
            print(msg)
            return
        time.sleep(3)
    sh(["xcrun", "simctl", "list", "pairs"], log)
    for d in (phone, watch):
        sh(["xcrun", "simctl", "spawn", d["udid"], "log", "show", "--last", "4m", "--style", "compact",
            "--predicate", 'process IN {"companiond","nanoregistryd","rapportd","identityservicesd"} AND (eventMessage CONTAINS[c] "pair" OR eventMessage CONTAINS[c] "compatib")'], log, timeout=45)
    raise RuntimeError(f"Pair {pair_id} stayed {state}; diagnostics: {log}")


def xcode_base(scheme, platform, udid, derived, config="Debug"):
    return ["xcodebuild", "-project", "Conduit.xcodeproj", "-scheme", scheme,
            "-destination", f"platform={platform} Simulator,id={udid}", "-configuration", config,
            "-derivedDataPath", str(derived), "-jobs", "4", "-packageAuthorizationProvider", "netrc",
            "-parallel-testing-enabled", "NO", *SIGNING]


def require_build_headroom():
    free = shutil.disk_usage(REPO).free / (1 << 30)
    if free < 86:
        raise RuntimeError(f"Only {free:.1f} GiB free; need 6 GiB build headroom above the 80 GiB floor")


def test_states(bundle):
    from suite import walk
    results = {}
    raw = capture("xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle))
    for node in json.loads(raw)["testNodes"]:
        walk(node, "", results)
    return results


def sim_ui(udid, setting, *value):
    result = subprocess.run(["xcrun", "simctl", "ui", udid, setting, *value],
                            env=env(), capture_output=True, text=True, timeout=30)
    return result.stdout.strip() if result.returncode == 0 else "unsupported"


def start_phone(udid, nonce, callable_, log):
    # An inert stub prevents reconnect, including when the simulator has
    # other test dashboards. Neither the sender nor the Watch UI makes a call.
    command = ["xcrun", "simctl", "launch", "--terminate-running-process", udid, PHONE_APP,
               "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://watch-lab.invalid",
               "-LAA_UI_TEST_ISOLATED_BRIDGE", "-laa-brain-no-vault-fixture"]
    e = dict(env(), SIMCTL_CHILD_LAA_WATCH_LAB_CONTEXT=nonce,
             SIMCTL_CHILD_LAA_WATCH_LAB_CALLABLE="yes" if callable_ else "no",
             SIMCTL_CHILD_LAA_BRIDGE_DEFAULT_ADDRESS="http://127.0.0.1:9")
    with log.open("a") as f:
        print(f"Launch phone WCSession sender; Call={'available' if callable_ else 'hidden'}", file=f, flush=True)
        subprocess.run(command, cwd=REPO, env=e, stdout=f, stderr=subprocess.STDOUT, check=True, timeout=25)


def run_variant(cmd, variables, phones, log):
    phone, watch = phones
    e = {**env(), **{f"TEST_RUNNER_LAA_WATCH_LAB_{k}": v for k, v in variables.items()}}
    with log.open("a") as f:
        print("$ " + " ".join(cmd), file=f, flush=True)
        with subprocess.Popen(cmd, cwd=REPO, env=e, stdout=f, stderr=subprocess.STDOUT) as process:
            try:
                if "NEXT" in variables:
                    sent = False
                    stop = time.monotonic() + 300
                    mark = f"laa-watch-lab-{variables['NEXT']}.ready"
                    while process.poll() is None and time.monotonic() < stop:
                        try:
                            root = capture("xcrun", "simctl", "get_app_container", watch, WATCH_RUNNER, "data",
                                           timeout=10, stderr=subprocess.DEVNULL)
                        except subprocess.CalledProcessError:
                            root = ""
                        if root and (Path(root) / "tmp" / mark).is_file():
                            start_phone(phone, variables["NEXT"], True, log)
                            sent = True
                            break
                        time.sleep(1)
                    rc = process.wait(timeout=240)
                    if not sent and rc == 0:
                        raise RuntimeError(f"Paired test did not request the second context; see {log}")
                    return rc
                return process.wait(timeout=300)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=30)


def export_variant(bundle, out, variant, expected, device, sha, log):
    exports = out / f"attachments-{variant}"
    sh(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(exports)],
       log, check=True, timeout=90)
    frames, proof = {}, None
    for test in json.loads((exports / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            name = attachment["suggestedHumanReadableName"]
            file = exports / attachment["exportedFileName"]
            if name.startswith("watch-appearance-proof"):
                proof = file.read_text().strip()
            for screen in expected:
                if file.suffix.lower() != ".png" or not re.match(rf"^watch-{screen}(?=[^a-z0-9-]|$)", name):
                    continue
                if screen in frames:
                    raise RuntimeError(f"Duplicate attachment {variant}/{screen}")
                relative = Path("watch") / variant / f"{screen}.png"
                target = out / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(file, target)
                data = target.read_bytes()
                if data[:8] != b"\x89PNG\r\n\x1a\n":
                    raise RuntimeError(f"Capture is not PNG: {target}")
                taken = datetime.fromtimestamp(attachment["timestamp"], timezone.utc).isoformat(timespec="milliseconds")
                frames[screen] = {"screen": screen, "variant": variant, "platform": "watch", "size": None,
                                  "path": str(relative), "sha256": hashlib.sha256(data).hexdigest(),
                                  "pixel_size": list(struct.unpack(">II", data[16:24])), "app_sha": sha,
                                  "simulator": {k: device[k] for k in ("name", "udid", "runtime")}, "taken_at": taken}
    if frames.keys() != set(expected) or not proof:
        raise RuntimeError(f"Missing Watch attachment(s): {set(expected) - frames.keys()}; proof={proof!r}")
    shutil.rmtree(exports)
    return list(frames.values()), proof


def run_tests(out, phone, watch):
    started = time.monotonic()
    require_build_headroom()
    phone_id, watch_id = phone["udid"], watch["udid"]
    sha = capture("git", "rev-parse", "HEAD")
    if capture("git", "status", "--porcelain", "-uno"):
        raise RuntimeError("Commit sources before generating verifiable screenshots")
    log = out / "build.log"
    sh(["xcodegen", "generate", "--spec", "project-laa.yml"], log, check=True)
    ios = [*xcode_base("ConduitWatchLabPhone", "iOS", phone_id, DERIVED),
           "CONDUIT_DEFAULT_RELAY_URL=http://127.0.0.1:9"]
    watch_base = [*xcode_base("ConduitWatchLab", "watchOS", watch_id, DERIVED),
                  "CONDUIT_DEFAULT_RELAY_URL=http://127.0.0.1:9"]
    sh([*ios, "build"], log, check=True, timeout=1800)
    sh([*watch_base, "build-for-testing"], log, check=True, timeout=1200)
    products = DERIVED / "Build/Products"
    phone_bundle = products / "Debug-iphonesimulator/Conduit.app"
    watch_bundle = products / "Debug-watchsimulator/ConduitWatch.app"
    for app, identifier in ((phone_bundle, PHONE_APP), (watch_bundle, WATCH_APP)):
        meta = plistlib.loads((app / "Info.plist").read_bytes())
        if meta.get("CFBundleIdentifier") != identifier:
            raise RuntimeError(f"Not the LAA Debug product: {app}")
        if identifier == WATCH_APP and meta.get("WKCompanionAppBundleIdentifier") != PHONE_APP:
            raise RuntimeError("Incorrect Watch companion bundle identifier")
    sim_log = out / "simulator.log"
    sh(["xcrun", "simctl", "install", phone_id, str(phone_bundle)], sim_log, check=True, timeout=90)
    sh(["xcrun", "simctl", "install", watch_id, str(watch_bundle)], sim_log, check=True, timeout=90)
    initial, next_ = str(uuid.uuid4()), str(uuid.uuid4())
    old_style, old_size = [sim_ui(watch_id, key) for key in ("appearance", "content_size")]
    variants = list(VARIANTS if old_style in ("light", "dark") else ("native", "long-ja-ax5"))
    frames, proof, bundles = [], {}, []
    try:
        for variant in variants:
            paired = variant in ("dark", "native")
            long = variant == "long-ja-ax5"
            wanted = variant if variant in ("light", "dark") else "native"
            if wanted != "native":
                sim_ui(watch_id, "appearance", wanted)
                if sim_ui(watch_id, "appearance") != wanted:
                    raise RuntimeError(f"Unable to set native Watch appearance {wanted}")
            if long and old_size not in ("unsupported", "unknown", ""):
                sim_ui(watch_id, "content_size", AX5)
            force_ax5 = long and sim_ui(watch_id, "content_size") != AX5
            variables = {"VARIANT": variant, "APPEARANCE": wanted, "FORCE_AX5": "1" if force_ax5 else "0"}
            tests = ["testHome"]
            expected = ["home"]
            log = out / f"ui-{variant}.log"
            if paired:
                start_phone(phone_id, initial, False, log)
                variables.update(INITIAL=initial, NEXT=next_)
                tests.append("testPhoneContext")
                expected += ["employee-no-call", "employee-call-available"]
            bundle = out / f"watch-{variant}.xcresult"
            bundles.append(bundle)
            cmd = [*watch_base, "test-without-building", "-resultBundlePath", str(bundle),
                   *[f"-only-testing:{WATCH_TEST}/{t}" for t in tests]]
            rc = run_variant(cmd, variables, (phone_id, watch_id), log)
            results = test_states(bundle) if bundle.exists() else {}
            log_json(out / f"results-{variant}.json", {"exit": rc, "tests": results})
            if rc or results.keys() != {f"{WATCH_TEST}/{test}" for test in tests} or any(
                    result["result"] != "Passed" for result in results.values()):
                raise RuntimeError(f"Watch {variant} failed or skipped ({rc}): {log}")
            entries, actual = export_variant(bundle, out, variant, expected, watch, sha, log)
            proof[variant] = {"system_appearance": sim_ui(watch_id, "appearance"), "swiftui": actual,
                              "content_size_source": "SwiftUI fixture" if force_ax5 else "watchOS"}
            frames += entries
        log_json(out / "index.json", {"schema": 1, "screens": [
            {"id": "home", "title": "LAA Watchホーム"},
            {"id": "employee-no-call", "title": "AI社員（通話不可）"},
            {"id": "employee-call-available", "title": "AI社員（通話可）"}],
            "images": frames, "variant_proof": proof, "wall_seconds": round(time.monotonic() - started, 2)})
        for bundle in bundles:
            shutil.rmtree(bundle)
    finally:
        for key, old in (("appearance", old_style), ("content_size", old_size)):
            if old not in ("unsupported", "unknown", "") and sim_ui(watch_id, key) != old:
                sim_ui(watch_id, key, old)
                if sim_ui(watch_id, key) != old:
                    raise RuntimeError(f"Watch simulator {key} not restored")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("pair-check", "test"))
    parser.add_argument("--out", type=Path, default=DERIVED / "pair-check")
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    if os.environ.get("LAA_BUILD_SLOT_HELD") != "1":
        return subprocess.run(["/bin/bash", SLOT, sys.executable, str(Path(__file__).resolve()),
                               args.command, "--out", str(args.out)], cwd=REPO, env=lab_env()).returncode
    started = time.monotonic()
    inventory = simulator_inventory()
    phone, watch = [named_device(n, inventory) for n in (PHONE_NAME, WATCH_NAME)]
    pair_id = named_pair(phone, watch)
    log = args.out / "simulator.log"
    with boot_devices((phone, watch), log):
        check_connected(pair_id, phone, watch, log)
        if args.command == "test":
            run_tests(args.out, phone, watch)
    print(f"{args.command} passed; slot held {time.monotonic() - started:.1f}s; output {args.out}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
