#!/usr/bin/env python3
"""Release UI measurements on the dedicated simulator; temporary read-only pairing.

The one-use pairing code travels only through process pipes and the simulator
pasteboard. Credentials stay in the app Keychain. No secrets in arguments/files.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

SIM = "DFFD3966-F54E-4C7A-A161-59201C7EA105"
BUILD = Path("/Users/laa/hq/harness/build_storage.py")
SLOT = "/Users/laa/hq/harness/build-slot.sh"
TESTS = ["ConduitUITests/LAAPerformanceUITests", "ConduitTests/LAAEmployeeChatPreviewTests",
         "ConduitTests/LAAWorkSessionCachePerformanceTests", "ConduitTests/LAAStaffMascotLoadingTests",
         "ConduitTests/WidgetLaunchCoordinatorTests"]


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def focus_test_sources(project):
    """Only the generated project changes; do not compile Debug-only tests in Release.

    xcodebuild -only-testing controls execution, not which source files the
    test target compiles. Preserve all application/extension build phases.
    """
    path = project / "project.pbxproj"
    config = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", path]))
    objects = config["objects"]
    for target in objects.values():
        name = target.get("name")
        if target.get("isa") != "PBXNativeTarget" or name not in {"ConduitTests", "ConduitUITests"}:
            continue
        wanted = {test.split('/')[1] + ".swift" for test in TESTS if test.startswith(name + '/')}
        found = set()
        for identifier in target["buildPhases"]:
            phase = objects[identifier]
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            keep = []
            for item in phase["files"]:
                reference = objects[objects[item]["fileRef"]]
                filename = Path(reference.get("path", reference.get("name", ""))).name
                if filename in wanted:
                    keep.append(item)
                    found.add(filename)
            phase["files"] = keep
        if found != wanted:
            raise RuntimeError("Focused test source list is incomplete")
    path.write_bytes(plistlib.dumps(config))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--build-root", type=Path)
    parser.add_argument("--skip-build", action="store_true", help="Measure the already-built Release product without rebuilding")
    parser.add_argument("--proxy-url", default=os.environ.get("LAA_PERF_PROXY_URL"),
                        help="Optional private proxy origin; never saved in results")
    parser.add_argument("--sim-lock", type=Path, default=Path("/Users/laa/work/laa-app-stage2-20261111/sim.lock"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    args.output.mkdir(parents=True, exist_ok=True)
    os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    probe = [sys.executable, repo / "scripts/laa/perf/probe.py",
             "--endpoint", "dashboard=http://127.0.0.1:9119/api/status"]
    if args.proxy_url:
        probe += ["--endpoint", "proxy=" + args.proxy_url.rstrip('/') + "/api/status"]
    root = args.build_root or Path(subprocess.check_output([sys.executable, str(BUILD), "create", "laa-s2-perf"], text=True).strip())
    (args.output / "build-root.txt").write_text(str(root) + "\n")
    (args.output / "revision.txt").write_text(subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True))
    run("xcodegen", "generate", "--spec", repo / "project-laa.yml", "--project", repo, stdout=subprocess.DEVNULL)
    focus_test_sources(repo / "Conduit.xcodeproj")
    base = ["/bin/bash", SLOT, "/usr/bin/python3", BUILD, "guard", "xcodebuild", "-project", repo / "Conduit.xcodeproj",
            "-scheme", "Conduit", "-configuration", "Release", "-destination", f"platform=iOS Simulator,id={SIM}",
            "-jobs", "4", "-derivedDataPath", root / "DerivedData", "CODE_SIGNING_ALLOWED=NO", "ENABLE_TESTABILITY=YES"]
    only = ["-only-testing:" + test for test in TESTS]
    if not args.skip_build:
        with (args.output / "build.log").open("w") as log:
            run(*base, "build-for-testing", *only, stdout=log, stderr=subprocess.STDOUT)
    spec = next((root / "DerivedData/Build/Products").glob("*.xctestrun"))
    config = plistlib.loads(spec.read_bytes())
    targets = [target for group in config.get("TestConfigurations", []) for target in group.get("TestTargets", [])]
    targets += [value for key, value in config.items() if key != "__xctestrun_metadata__" and isinstance(value, dict) and "TestBundlePath" in value]
    for target in targets:
        target.setdefault("EnvironmentVariables", {})["LAA_PERF_RUN"] = "1"
    spec.write_bytes(plistlib.dumps(config))
    args.sim_lock.mkdir()
    (args.sim_lock / "owner").write_text("PERF\n")
    pairing_hash = None
    try:
        inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
        simulator = next(device for group in inventory["devices"].values() for device in group if device["udid"] == SIM)
        if simulator["state"] != "Booted":
            run("xcrun", "simctl", "boot", SIM, stdout=subprocess.DEVNULL)
        run("xcrun", "simctl", "bootstatus", SIM, "-b", stdout=subprocess.DEVNULL)
        run(*probe, "--output", args.output / "network-before.json", stdout=subprocess.DEVNULL)
        pairing = json.loads(subprocess.check_output(["laa-bridge", "pair", "--name", "LAA PERF temporary", "--scopes", "sessions:read,brain:read,media:read,usage:read", "--json"]))
        code = pairing.get("code") or pairing.get("data", {}).get("code")
        if not code:
            raise RuntimeError("Pairing command returned no code")
        normalized = "".join(code.replace("-", "").split()).upper()
        pairing_hash = hashlib.sha256(("pair:" + normalized).encode()).hexdigest()
        run("xcrun", "simctl", "pbcopy", SIM, input=code.encode())
        command = ["/bin/bash", SLOT, "/usr/bin/python3", BUILD, "guard", "xcodebuild", "test-without-building",
                   "-xctestrun", spec, "-destination", f"platform=iOS Simulator,id={SIM}", "-jobs", "4",
                   "-parallel-testing-enabled", "NO", *only,
                   "-resultBundlePath", args.output / "results.xcresult"]
        with (args.output / "test.log").open("w") as log:
            run(*command, stdout=log, stderr=subprocess.STDOUT)
    finally:
        # Resolve only OUR one-use code to its enrolled device. Parallel tests
        # may create other devices with the same UIKit name; never revoke them.
        state = Path.home() / ".local/state/laa-bridge/state.json"
        cleanup_errors = []
        try:
            if pairing_hash:
                pairing_state = json.loads(state.read_text()).get("pairings", {}).get(pairing_hash, {})
                identity = pairing_state.get("deviceId")
                if identity:
                    run("laa-bridge", "revoke", identity, "--reason", "PERF measurement finished", stdout=subprocess.DEVNULL)
        except Exception as error:
            cleanup_errors.append(type(error).__name__)
        for command, options in [(["xcrun", "simctl", "pbcopy", SIM], {"input": b""}),
                                 (["xcrun", "simctl", "shutdown", SIM], {"stdout": subprocess.DEVNULL})]:
            try:
                run(*command, **options)
            except Exception as error:
                cleanup_errors.append(type(error).__name__)
        (args.sim_lock / "owner").unlink()
        args.sim_lock.rmdir()
        run(*probe, "--output", args.output / "network-after.json", stdout=subprocess.DEVNULL)
        if cleanup_errors:
            raise RuntimeError("Temporary measurement cleanup failed: " + ','.join(cleanup_errors)) from None
    run(sys.executable, repo / "scripts/laa/perf/summarize.py", args.output / "test.log", "--output", args.output / "summary.json")


if __name__ == "__main__":
    main()
