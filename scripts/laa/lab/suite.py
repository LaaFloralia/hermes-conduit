#!/usr/bin/env python3
"""Run a named test suite on the simulator and ratchet its failures.

Two suites, kept apart on purpose (BUS-504): `integration` is the LAA build
(project-laa.yml) with every unit and UI class; `smoke` is the default Conduit
build (project.yml) with the merge gate's selection. A count is never the
verdict: every failed or skipped test is named with a fingerprint of its first
failure, and `check` compares names and fingerprints with
scripts/laa/lab/known-failures.json.

  suite.py run integration --out <dir> [--phase build|unit|ui|all] [--only Target/Class[/test] ...]
  suite.py parse <dir>                       # xcresult bundles -> <dir>/results.json
  suite.py check integration <dir> [--partial]
  suite.py seed integration <dir>            # print known-failures entries for the unlisted ones

Every xcodebuild holds the shared build slot and boots the simulator only for
its own run. Real-Bridge opt-ins are removed from the environment, so a suite
run never talks to production.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
LAB = Path(__file__).resolve().parent
SLOT = "/Users/laa/hq/harness/build-slot.sh"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
PHONE = "DFFD3966-F54E-4C7A-A161-59201C7EA105"  # LAA 16 Pro Max, iOS 27.0
SIGNING = ["CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "GIT_TERMINAL_PROMPT=0"]
# Opt-ins that point a test at the production Bridge. Never inherited.
FORBIDDEN_ENV = ("LAA_UI_TEST_REAL_BRIDGE", "LAA_REAL_BRIDGE_TEST")
CLASS_RE = re.compile(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*([\w.]+)", re.M)


def suites():
    return json.loads((LAB / "suites.json").read_text())


def env():
    e = {k: v for k, v in os.environ.items() if k.replace("TEST_RUNNER_", "") not in FORBIDDEN_ENV}
    e["DEVELOPER_DIR"] = DEVELOPER_DIR
    return e


def sh(cmd, log=None, check=False, timeout=None):
    """Run a command; the full output goes to `log`. Returns the exit code."""
    if log:
        with open(log, "ab") as f:
            f.write(("\n$ " + " ".join(cmd) + "\n").encode())
            f.flush()
            rc = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env(), cwd=REPO, timeout=timeout).returncode
    else:
        rc = subprocess.run(cmd, env=env(), cwd=REPO, timeout=timeout).returncode
    if check and rc != 0:
        raise SystemExit(f"failed ({rc}): {' '.join(cmd[:6])} … log: {log}")
    return rc


def classes(target):
    """Every XCTestCase class in a target, by source scan (LAA-only files included)."""
    found, parents = {}, {}
    for path in sorted((REPO / target).rglob("*.swift")):
        for name, parent in CLASS_RE.findall(path.read_text(errors="replace")):
            parents[name] = parent
            found[name] = str(path.relative_to(REPO))

    def is_test(name, seen=()):
        parent = parents.get(name)
        if parent == "XCTestCase":
            return True
        return parent in parents and parent not in seen and is_test(parent, seen + (name,))

    return sorted(n for n in found if is_test(n))


def inventory(out, target):
    """The tests the built bundle really holds (`xcodebuild -enumerate-tests`), or None.

    The build decides what exists: LAA-only and Catalyst-only classes are
    compiled out of some builds, which a source scan cannot see.
    """
    path = Path(out) / f"inventory-{target}.json"
    if not path.exists():
        return None
    values = json.loads(path.read_text()).get("values", [])
    return sorted({t["identifier"].replace("()", "") for v in values for t in v.get("enabledTests", [])})


def enumerate_tests(derived, out, target):
    path = Path(out) / f"inventory-{target}.json"
    subprocess.run(["rm", "-f", str(path)])
    rc = xcodebuild("test-without-building", derived, [f"-only-testing:{target}", "-enumerate-tests", "-test-enumeration-style", "flat",
                    "-test-enumeration-format", "json", "-test-enumeration-output-path", f"'{path}'"], Path(out) / f"inventory-{target}.log")
    if rc != 0 or not inventory(out, target):
        raise SystemExit(f"could not enumerate {target} ({rc}); log: {Path(out) / f'inventory-{target}.log'}")


def select(suite, target_key, out=None):
    spec = suite[target_key]
    target = "ConduitTests" if target_key == "unit" else "ConduitUITests"
    if spec == "all":
        listed = inventory(out, target) if out else None
        names = sorted({i.split("/")[1] for i in listed}) if listed else classes(target)
    elif isinstance(spec, str) and spec.startswith("smoke-plan"):
        with tempfile.NamedTemporaryFile(suffix=".json") as tmp:
            subprocess.run([sys.executable, "scripts/plan-tests.py", "smoke", "--repo-root", ".", "--suite", "scripts/smoke-suite.json",
                            "--out", tmp.name], cwd=REPO, capture_output=True, text=True, check=True)
            plan = json.loads(Path(tmp.name).read_text())
        names = plan["unit" if target_key == "unit" else "ui"]
    else:
        names = list(spec)
    return [n for n in names if n not in set(suite.get("exclude_classes", {}))]


def prepare_simulator(log):
    """Erase the phone, set English (US) and read it back, shut down (handoff: the smoke device).

    Runs inside the build slot: another session's test may be using the same simulator.
    """
    inner = (f"set -e; xcrun simctl shutdown {PHONE} 2>/dev/null || true; xcrun simctl erase {PHONE}; "
             f"xcrun simctl boot {PHONE}; xcrun simctl bootstatus {PHONE} >/dev/null; "
             f"xcrun simctl spawn {PHONE} defaults write -g AppleLanguages -array en-US; "
             f"xcrun simctl spawn {PHONE} defaults write -g AppleLocale en_US; "
             f"xcrun simctl spawn {PHONE} defaults read -g AppleLanguages | grep -q en-US; "
             f"xcrun simctl shutdown {PHONE}")
    if sh(["/bin/bash", SLOT, "/bin/bash", "-c", inner], log) != 0:
        raise SystemExit(f"simulator was not erased and set to en-US; log: {log}")


def start_fixtures(suite, out):
    procs = []
    for name, cmd in suite.get("fixtures", {}).items():
        log = open(out / f"fixture-{name}.log", "ab")
        procs.append(subprocess.Popen(cmd, cwd=REPO, stdout=log, stderr=subprocess.STDOUT, env=env()))
    if procs:
        time.sleep(3)
        dead = [p.args for p in procs if p.poll() is not None]
        if dead:
            stop_fixtures(procs)
            raise SystemExit(f"fixture exited at start (port in use?): {dead}")
    return procs


def stop_fixtures(procs):
    for p in procs:
        p.terminate()
    for p in procs:
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()


def xcodebuild(action, derived, extra, log, bundle=None):
    # A build needs no booted simulator; booting one beside the compile only adds load.
    boot = "" if action == "build-for-testing" else f"xcrun simctl boot {PHONE} 2>/dev/null; xcrun simctl bootstatus {PHONE} >/dev/null; "
    inner = (boot + f"xcodebuild {action} -project Conduit.xcodeproj -scheme Conduit -destination 'platform=iOS Simulator,id={PHONE}' "
             f"-derivedDataPath {derived} -jobs 4 -packageAuthorizationProvider netrc {' '.join(extra)} "
             + (f"-resultBundlePath '{bundle}' " if bundle else "") + " ".join(SIGNING)
             + ("" if action == "build-for-testing" else f"; rc=$?; xcrun simctl shutdown {PHONE}; exit $rc"))
    return sh(["/bin/bash", SLOT, "/bin/bash", "-c", inner], log)


def cmd_run(args):
    suite = suites()[args.suite]
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    derived = suite.get("derived", f".deriveddata-lab-{args.suite}")
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=REPO, capture_output=True, text=True).stdout.strip()
    meta = {"suite": args.suite, "spec": suite["spec"], "sha": head, "dirty": bool(dirty), "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "only": args.only, "phases": {}}
    phases = ["build", "unit", "ui"] if args.phase == "all" else [args.phase]

    # One run per checkout: a second run would regenerate Conduit.xcodeproj
    # from another spec under the first one's remaining batches. Use a second
    # worktree to run two suites side by side.
    lock = open(REPO / ".lab-suite.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise SystemExit(f"another suite run holds {REPO}/.lab-suite.lock; use a separate worktree")
    sh(["xcodegen", "generate", "--spec", suite["spec"]], out / "xcodegen.log", check=True)
    if "build" in phases:
        if not args.no_erase:
            prepare_simulator(out / "simulator.log")
        rc = xcodebuild("build-for-testing", derived, [], out / "build.log")
        meta["phases"]["build"] = rc
        if rc != 0:
            (out / "run.json").write_text(json.dumps(meta, indent=1))
            raise SystemExit(f"build-for-testing failed ({rc}); log: {out / 'build.log'}")
    for key, target in (("unit", "ConduitTests"), ("ui", "ConduitUITests")):
        if suite[key] and inventory(out, target) is None and ("build" in phases or key in phases):
            enumerate_tests(derived, out, target)

    def batch(kind, names, size):
        if args.only:
            return [[f"-only-testing:{o}" for o in args.only]] if any(o.startswith(kind) for o in args.only) else []
        target = "ConduitTests" if kind == "ConduitTests" else "ConduitUITests"
        return [[f"-only-testing:{target}/{n}" for n in names[i:i + size]] for i in range(0, len(names), size)]

    if "unit" in phases:
        batches = [["-only-testing:ConduitTests"]] if suite["unit"] == "all" and not args.only else batch("ConduitTests", select(suite, "unit", out), 400)
        for i, only in enumerate(batches):
            bundle = out / f"unit-{i}.xcresult"
            subprocess.run(["rm", "-rf", str(bundle)])
            meta["phases"][f"unit-{i}"] = xcodebuild("test-without-building", derived, only, out / f"unit-{i}.log", bundle)
    if "ui" in phases:
        fixtures = start_fixtures(suite, out)
        try:
            for i, only in enumerate(batch("ConduitUITests", select(suite, "ui", out), suite.get("ui_batch", 6))):
                bundle = out / f"ui-{i}.xcresult"
                subprocess.run(["rm", "-rf", str(bundle)])
                meta["phases"][f"ui-{i}"] = xcodebuild("test-without-building", derived, only, out / f"ui-{i}.log", bundle)
                (out / "run.json").write_text(json.dumps(meta, indent=1))
        finally:
            stop_fixtures(fixtures)
    meta["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    (out / "run.json").write_text(json.dumps(meta, indent=1))
    cmd_parse(args)
    print(json.dumps(meta["phases"]))
    return 0


def fingerprint(message):
    """Stable across runs: numbers, addresses, paths and long quoted text are folded away."""
    text = re.sub(r"0x[0-9a-fA-F]+", "H", message)
    text = re.sub(r"/[\w./@+-]*/([\w.+-]+\.swift)", r"\1", text)
    text = re.sub(r"\d+(\.\d+)?", "N", text)
    text = re.sub(r"\s+", " ", text).strip()[:400]
    return hashlib.sha1(text.encode()).hexdigest()[:12]


def walk(node, target, found):
    kind = node.get("nodeType")
    if kind in ("Unit test bundle", "UI test bundle"):
        target = node.get("name", target)
    if kind == "Test Case":
        ident = f"{target}/{node.get('nodeIdentifier', node.get('name'))}".replace("()", "")
        messages = []

        def collect(n):
            for child in n.get("children", []):
                if child.get("nodeType") == "Failure Message":
                    messages.append(child.get("name", ""))
                collect(child)
        collect(node)
        result = node.get("result", "")
        entry = {"result": result, "seconds": node.get("durationInSeconds")}
        if result not in ("Passed",):
            first = messages[0] if messages else ""
            entry["message"] = first[:400]
            entry["fingerprint"] = fingerprint(first) if result == "Failed" else None
            entry["failures"] = len(messages)
        # A test that ran in two bundles (a rerun) keeps the later result.
        found[ident] = entry
        return
    for child in node.get("children", []):
        walk(child, target, found)


def cmd_parse(args):
    out = Path(args.out).resolve()
    found = {}
    for bundle in sorted(out.glob("*.xcresult"), key=lambda p: p.stat().st_mtime):
        raw = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle), "--compact"],
                             capture_output=True, text=True, env=env())
        if raw.returncode != 0:
            print(f"unreadable result bundle: {bundle.name}: {raw.stderr.strip()[:200]}", file=sys.stderr)
            continue
        for node in json.loads(raw.stdout).get("testNodes", []):
            walk(node, "", found)
    counts = {}
    for entry in found.values():
        counts[entry["result"]] = counts.get(entry["result"], 0) + 1
    (out / "results.json").write_text(json.dumps({"counts": counts, "tests": dict(sorted(found.items()))}, indent=1, ensure_ascii=False))
    print(json.dumps(counts))
    return 0


def load(out):
    return json.loads((Path(out) / "results.json").read_text())["tests"]


def cmd_check(args):
    suite = suites()[args.suite]
    tests = load(args.out)
    known = json.loads((LAB / "known-failures.json").read_text()).get(args.suite, {})
    problems = []
    for ident, entry in tests.items():
        bad = entry["result"] != "Passed"
        listed = known.get(ident)
        if bad and not listed:
            problems.append(f"NEW {entry['result'].upper()}: {ident} [{entry.get('fingerprint')}] {entry.get('message', '')[:160]}")
        elif bad and listed.get("result") != entry["result"]:
            problems.append(f"CHANGED RESULT: {ident} is {entry['result']}, listed as {listed.get('result')}")
        elif bad and entry["result"] == "Failed" and listed.get("fingerprint") not in (entry["fingerprint"], "*"):
            problems.append(f"DIFFERENT FAILURE: {ident} [{entry['fingerprint']}], listed [{listed.get('fingerprint')}] {entry.get('message', '')[:160]}")
        elif not bad and listed:
            problems.append(f"NOW PASSES, remove from known-failures.json: {ident}")
    if not args.partial:
        for ident in known:
            if ident not in tests:
                problems.append(f"LISTED BUT DID NOT RUN: {ident}")
        for key, target in (("unit", "ConduitTests"), ("ui", "ConduitUITests")):
            if not suite[key]:
                continue
            listed = inventory(args.out, target)
            if listed is None:
                problems.append(f"NO INVENTORY for {target}: run the build phase (inventory-{target}.json)")
                continue
            wanted = set(select(suite, key, args.out))
            for ident in listed:
                if ident.split("/")[1] in wanted and ident not in tests:
                    problems.append(f"IN THE BUILD BUT DID NOT RUN: {ident}")
            for name in wanted - {i.split("/")[1] for i in listed}:
                problems.append(f"SELECTED CLASS IS NOT IN THE BUILD: {name}")
    for ident, listed in known.items():
        if not listed.get("reason") or listed.get("class") not in ("stale-expectation", "environment", "real-bug", "not-applicable"):
            problems.append(f"LISTED WITHOUT A REASON OR CLASS: {ident}")
    for name, reason in suite.get("exclude_classes", {}).items():
        if not str(reason).strip():
            problems.append(f"EXCLUDED CLASS WITHOUT A REASON: {name}")
        if any(ident.split("/")[1] == name for ident in tests if ident.count("/") >= 2):
            problems.append(f"EXCLUDED CLASS RAN: {name}")
    counts = {}
    for entry in tests.values():
        counts[entry["result"]] = counts.get(entry["result"], 0) + 1
    print(f"{args.suite}: {counts}; listed exceptions {len(known)}; problems {len(problems)}")
    for line in problems:
        print("  " + line)
    return 1 if problems else 0


def cmd_seed(args):
    tests = load(args.out)
    known = json.loads((LAB / "known-failures.json").read_text()).get(args.suite, {}) if (LAB / "known-failures.json").exists() else {}
    seed = {ident: {"result": e["result"], "fingerprint": e.get("fingerprint"), "class": "", "reason": "", "message": e.get("message", "")[:200]}
            for ident, e in tests.items() if e["result"] != "Passed" and ident not in known}
    print(json.dumps(seed, indent=1, ensure_ascii=False))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run"); run.add_argument("suite"); run.add_argument("--out", required=True)
    run.add_argument("--phase", default="all", choices=["all", "build", "unit", "ui"]); run.add_argument("--only", nargs="*", default=[])
    run.add_argument("--no-erase", action="store_true", help="keep the simulator's data (a unit run beside another session's UI run)")
    parse = sub.add_parser("parse"); parse.add_argument("out")
    for name in ("check", "seed"):
        p = sub.add_parser(name); p.add_argument("suite"); p.add_argument("out")
        if name == "check":
            p.add_argument("--partial", action="store_true", help="a subset ran: skip the did-not-run checks")
    args = parser.parse_args()
    return {"run": cmd_run, "parse": cmd_parse, "check": cmd_check, "seed": cmd_seed}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
