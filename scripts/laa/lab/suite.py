#!/usr/bin/env python3
"""Run a named test suite on the simulator and ratchet its failures.

Two suites, kept apart on purpose (BUS-504): `integration` is the LAA build
(project-laa.yml) with every unit and UI class; `smoke` is the default Conduit
build (project.yml) with the merge gate's selection. A count is never the
verdict: every failed or skipped test is named with a fingerprint of its first
failure, and `check` compares names and fingerprints with
scripts/laa/lab/known-failures.json.

  suite.py run integration --out <dir> [--host auto|macbook|mini] [--phase build|unit|ui|all]
           [--dry-run] [--only Target/Class[/test] ...]
  suite.py parse <dir>                       # xcresult bundles -> <dir>/results.json
  suite.py check integration <dir> [--partial]
  suite.py seed integration <dir>            # print known-failures entries for the unlisted ones

Route the whole run under one host slot: one build-for-testing, then reuse its
.xctestrun for enumeration and tests. Units share a simulator session across
28-class batches; UI batches still start clean unless --no-erase. Only the
selected simulator is touched, and only if it was idle before the run.
Real-Bridge opt-ins are removed; integration UI requires a private lab lane.
Dry-run prints the route and a source-based batch estimate without using either
host's slot, waking the MacBook, or writing files.

A phase whose runner never started (no test ran) is repeated once. A failure
that is not in known-failures.json is run once more on its own (at most
RERUN_LIMIT per target, --no-rerun to skip); a test that passes only there
stays marked in results.json and `check` prints it, so it is never silently
green.
"""
import argparse
import fcntl
from functools import lru_cache
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
LAB = Path(__file__).resolve().parent
SLOT = "/Users/laa/hq/harness/build-slot.sh"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
PHONE_NAME, PHONE_RUNTIME = "LAA 16 Pro Max", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
SCHEME = "Conduit"
SIGNING = ["CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "GIT_TERMINAL_PROMPT=0"]
# Opt-ins that point a test at the production Bridge. Never inherited.
FORBIDDEN_ENV = ("LAA_UI_TEST_REAL_BRIDGE", "LAA_REAL_BRIDGE_TEST")
TARGETS = {"unit": "ConduitTests", "ui": "ConduitUITests"}
UNIT_BATCH = 28
BUILD_FAILURE = 75  # the router may retry only a failed build, never a test or fixture
RERUN_LIMIT = 10  # more unexpected failures than this is a broken change, not noise
CLASS_RE = re.compile(r"^\s*(?:(?:private|fileprivate|internal|public|open|final)\s+)*class\s+(\w+)\s*:\s*([\w.]+)", re.M)
ONLY_RE = re.compile(r"(ConduitTests|ConduitUITests)/\w+(?:/\w+(?:\(\))?)?\Z")
RESULT_RE = re.compile(r"(?:run|results)\.json|(?:build|simulator|xcodegen|fixtures)\.log|"
                       r"inventory-Conduit(?:UI)?Tests\.(?:log|json(?:\.attempt1)?)|"
                       r"(?:(?:unit|ui)-[0-9]+|rerun-(?:unit|ui))\.(?:log|xcresult(?:\.attempt1)?)")


def suites():
    return json.loads((LAB / "suites.json").read_text())


def env(test_env=None):
    def safe(key):
        key = key.removeprefix("TEST_RUNNER_")
        return key not in FORBIDDEN_ENV and not key.startswith("LAA_LANE_") and key != "LAA_LAB_SIMULATOR"

    e = {k: v for k, v in os.environ.items() if safe(k)}
    e["DEVELOPER_DIR"] = DEVELOPER_DIR
    if e.get("LAA_MB_HOST") == "macbook":
        e["PATH"] = f"{e.get('PATH', os.defpath)}:/opt/homebrew/bin"
    e.update(test_env or {})
    return e


def sh(cmd, log, check=False, timeout=None, test_env=None):
    """Run a command with its full output saved to log, returning its exit code."""
    with open(log, "ab") as f:
        f.write(("\n$ " + shlex.join(cmd) + "\n").encode())
        f.flush()
        rc = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env(test_env), cwd=REPO, timeout=timeout).returncode
    if check and rc != 0:
        raise RuntimeError(f"failed ({rc}): {' '.join(cmd[:4])}; log: {log}")
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
        if parent in ("XCTestCase", "XCTest.XCTestCase"):
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
    try:
        listing = json.loads(path.read_text())
        found = sorted({t["identifier"].replace("()", "") for v in listing.get("values", []) for t in v.get("enabledTests", [])})
    except (ValueError, AttributeError, KeyError, TypeError):
        return None
    # A runner that failed to launch still exits 0 and lists only the bundle
    # itself (2026-11-24): errors or anything but Target/Class/test is no inventory.
    if listing.get("errors") or not found or not all(real(i) for i in found):
        return None
    return found


def enumerate_tests(sim, xctestrun, out, target):
    path, log = out / f"inventory-{target}.json", out / f"inventory-{target}.log"
    for attempt in (1, 2):  # once more when the runner did not launch
        if path.exists():
            path.rename(f"{path}.attempt1")
        rc = run_tests(sim, xctestrun, [f"-only-testing:{target}", "-enumerate-tests", "-test-enumeration-style", "flat",
                                       "-test-enumeration-format", "json", "-test-enumeration-output-path", str(path)], log)
        if rc == 0 and inventory(out, target):
            return
    raise RuntimeError(f"could not enumerate {target} ({rc}); log: {log}")


@lru_cache(maxsize=1)
def smoke_plan():
    # The planner validates names without --out; keep its curated list and
    # source contracts without writing a temporary plan (including dry-run).
    path = "scripts/smoke-suite.json"
    result = subprocess.run([sys.executable, "-B", "scripts/plan-tests.py", "smoke", "--repo-root", ".", "--suite", path],
                            cwd=REPO, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"invalid smoke plan: {result.stdout or result.stderr}")
    plan = json.loads((REPO / path).read_text())
    plan["unit"] += plan.get("source_contracts", [])
    return plan


def select(suite, target_key, out=None):
    spec, target = suite[target_key], TARGETS[target_key]
    if spec == "all":
        listed = inventory(out, target) if out else None
        names = sorted({i.split("/")[1] for i in listed}) if listed else classes(target)
    elif isinstance(spec, str) and spec.startswith("smoke-plan"):
        names = smoke_plan()[target_key]
    else:
        names = list(spec)
    return [n for n in names if n not in suite.get("exclude_classes", {})]


def batches(suite, kind, only, out=None):
    target = TARGETS[kind]
    size = UNIT_BATCH if kind == "unit" else suite.get("ui_batch", 6)
    grouped = {}
    for ident in only or [f"{target}/{name}" for name in select(suite, kind, out)]:
        if not ident.startswith(target + "/"):
            continue
        _, name, *_ = ident.split("/")
        grouped.setdefault(name, []).append(f"-only-testing:{ident}")
    groups = list(grouped.values())
    return [[flag for group in groups[i:i + size] for flag in group] for i in range(0, len(groups), size)]


def sim_devices():
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], env=env(), timeout=30)
    return json.loads(raw)["devices"]


MINI_SWAP_LIMIT = 0.85  # refuse to boot a simulator on the Mac mini above this swap use
MINI_FREE_FLOOR = 20    # ... or below this system-wide free memory percentage


def mini_memory_guard(read=subprocess.check_output):
    """Refuse an explicit --host mini simulator boot that would starve Hermes.

    The Mac mini serves the owner's chats (Hermes, gateway, relay, Bridge). A
    booted simulator took swap to 96% there and stalled every employee chat
    (D-25), so a mini run only boots while swap and free memory leave room.
    """
    swap = read(["sysctl", "-n", "vm.swapusage"], text=True, env=env(), timeout=10)
    fields = dict(re.findall(r"(total|used)\s*=\s*([0-9.]+)M", swap))
    total, used = float(fields.get("total", 0)), float(fields.get("used", 0))
    pressure = read(["memory_pressure", "-Q"], text=True, env=env(), timeout=30)
    free = re.search(r"free percentage:\s*([0-9]+)%", pressure)
    if free is None:
        raise RuntimeError("Mac mini memory guard could not read memory_pressure; not booting a simulator")
    if total > 0 and used / total > MINI_SWAP_LIMIT:
        raise RuntimeError(f"Mac mini swap is {used / total:.0%} used (limit {MINI_SWAP_LIMIT:.0%}); "
                           "not booting a simulator next to the chat services. Use --host macbook.")
    if int(free.group(1)) < MINI_FREE_FLOOR:
        raise RuntimeError(f"Mac mini free memory is {free.group(1)}% (floor {MINI_FREE_FLOOR}%); "
                           "not booting a simulator next to the chat services. Use --host macbook.")


class Simulator:
    def __init__(self, out):
        matches = [d["udid"] for d in sim_devices().get(PHONE_RUNTIME, [])
                   if d["name"] == PHONE_NAME and d.get("isAvailable")]
        if len(matches) != 1:
            raise RuntimeError(f"expected one available {PHONE_NAME} ({PHONE_RUNTIME}); found {len(matches)}")
        self.udid, self.log, self.owned = matches[0], out / "simulator.log", False

    def call(self, *args):
        sh(["xcrun", "simctl", *args], self.log, check=True, timeout=180)

    def start(self, erase=False):
        devices = [d for group in sim_devices().values() for d in group]
        active = [d["name"] for d in devices if d["state"] not in ("Shutdown", "Unknown")
                  and not (self.owned and d["udid"] == self.udid)]
        current = next((d["state"] for d in devices if d["udid"] == self.udid), None)
        if active or current is None or (not self.owned and current != "Shutdown"):
            raise RuntimeError(f"will not take over a simulator: {', '.join(active) or self.udid}")
        if self.owned:
            if not erase and current == "Booted":
                return
            self.stop()
        if os.environ.get("LAA_MB_HOST") == "mini":
            mini_memory_guard()
        if erase:
            self.call("erase", self.udid)
        self.call("boot", self.udid)
        self.owned = True
        self.call("bootstatus", self.udid)
        if erase:
            for key, value in (("AppleLanguages", "en-US"), ("AppleLocale", "en_US")):
                self.call("spawn", self.udid, "defaults", "write", "-g", key,
                          *(["-array"] if key == "AppleLanguages" else []), value)
                readback = subprocess.check_output(["xcrun", "simctl", "spawn", self.udid, "defaults", "read", "-g", key],
                                                   text=True, env=env(), timeout=30)
                if value not in readback:
                    raise RuntimeError(f"simulator {key} was not set to {value}")

    def stop(self):
        if self.owned:
            def state():
                return next(d["state"] for group in sim_devices().values() for d in group if d["udid"] == self.udid)

            if state() not in ("Shutdown", "Shutting Down"):
                self.call("shutdown", self.udid)
            for _ in range(30):
                if state() == "Shutdown":
                    self.owned = False
                    return
                time.sleep(1)
            raise RuntimeError(f"simulator did not shut down; log: {self.log}")


def start_fixtures(suite, out, udid):
    names = suite.get("fixtures")
    if not names:
        return None
    command, log = ["node", str(LAB / "lane.mjs")], out / "fixtures.log"
    # Keep Unix sockets short and private fixture state out of routed results.
    scratch = Path(tempfile.mkdtemp(prefix="hort-lab-", dir="/tmp"))
    lane_env = env({"LAA_LANE_PARENT": str(scratch)})
    with log.open("a") as stream:
        started = subprocess.run(command + ["up", "--json"] + [arg for name in names for arg in ("--fixture", name)],
                                 cwd=REPO, env=lane_env, stdout=subprocess.PIPE, stderr=stream,
                                 text=True, timeout=120)
        stream.write(started.stdout)  # public manifest only; no bearer or pairing code
    if started.returncode:
        if not any(scratch.iterdir()):
            scratch.rmdir()
        raise RuntimeError(f"isolated lane startup failed on {os.environ['LAA_MB_HOST']}; log: {log}")
    lane = json.loads(started.stdout)
    values = {"LAA_LANE_ID": lane["id"], "LAA_LANE_BRIDGE": lane["bridge"], "LAA_LAB_SIMULATOR": udid}
    values.update({f"LAA_LANE_FIXTURE_{name.upper().replace('-', '_')}": f"http://127.0.0.1:{port}"
                   for name, port in lane["ports"].items() if name != "bridge"})
    return command, lane["root"], log, scratch, {f"TEST_RUNNER_{k}": v for k, v in values.items()}


def stop_fixtures(fixture):
    if fixture is None:
        return
    command, root, log, scratch, _ = fixture
    sh(command + ["down", root], log, check=True, timeout=120)
    if Path(root).exists():
        raise RuntimeError(f"lane root remained after shutdown: {root}")
    scratch.rmdir()


def destination(sim):
    return ["-destination", f"platform=iOS Simulator,id={sim.udid}", "-jobs", "4", "-parallel-testing-enabled", "NO"]


def build_for_testing(suite, sim, derived, packages, out):
    sh(["xcodegen", "generate", "--spec", suite["spec"]], out / "xcodegen.log", check=True)
    rc = sh(["xcodebuild", "build-for-testing", "-project", "Conduit.xcodeproj", "-scheme", SCHEME, *destination(sim),
             "-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", str(packages),
             "-packageAuthorizationProvider", "netrc", *SIGNING], out / "build.log")
    if rc:
        return rc, None
    # Match the CI build-once runner: use this build's newest test manifest.
    manifests = list((derived / "Build/Products").glob(f"{SCHEME}*iphonesimulator*.xctestrun"))
    if not manifests:
        raise RuntimeError(f"build-for-testing produced no {SCHEME} Simulator .xctestrun in {derived}")
    return rc, max(manifests, key=lambda p: p.stat().st_mtime_ns)


def run_tests(sim, xctestrun, extra, log, bundle=None, test_env=None):
    cmd = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), *destination(sim), *extra]
    if bundle:
        cmd += ["-resultBundlePath", str(bundle)]
    return sh(cmd, log, test_env=test_env)


def real(ident):
    """A test case, not xcodebuild's pseudo entry for a runner that failed to start."""
    return ident.count("/") >= 2


def ran(bundle):
    """True when the bundle holds at least one real test case."""
    if not Path(bundle).exists():
        return False
    raw = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle), "--compact"],
                         capture_output=True, text=True, env=env())
    if raw.returncode != 0:
        return False
    found = {}
    for node in json.loads(raw.stdout).get("testNodes", []):
        walk(node, "", found)
    return any(real(i) for i in found)


def explained(listed, entry):
    return bool(listed) and listed.get("result") == entry["result"] and (
        entry["result"] != "Failed" or listed.get("fingerprint") == entry.get("fingerprint"))


def unexpected(suite_name, tests, target):
    known = json.loads((LAB / "known-failures.json").read_text()).get(suite_name, {})
    return sorted(i for i, e in tests.items()
                  if i.startswith(target + "/") and real(i) and e["result"] == "Failed" and not explained(known.get(i), e))


def test_phases(args, suite):
    for kind, target in TARGETS.items():
        if suite[kind] and args.phase in ("all", kind) and (not args.only or any(o.startswith(target + "/") for o in args.only)):
            yield kind, target


def route(args, suite, out, source):
    label = f"hortensia-lab-{args.suite}-{args.phase}"
    worker = ["python3", "-B", "scripts/laa/lab/suite.py", "run", args.suite,
              "--phase", args.phase, "--_worker-source", json.dumps(source, separators=(",", ":"))]
    if args.no_erase:
        worker.append("--no-erase")
    if args.no_rerun:
        worker.append("--no-rerun")
    if args.only:
        worker += ["--only", *args.only]
    derived = REPO / suite.get("derived", f".deriveddata-lab-{args.suite}")
    packages = derived / "SourcePackages"
    route_env = {"LAA_BUILD_PRIORITY": "unsigned", "LAA_BUILD_LABEL": label}
    if args.host == "mini":
        route_env.update(LAA_MB_SRC=str(REPO), LAA_MB_DD=str(derived), LAA_MB_OUT=str(out),
                         LAA_MB_PACKAGES=str(packages), LAA_MB_HOST="mini")
        return ["/bin/bash", os.environ.get("LAA_BUILD_SLOT", SLOT), *worker], route_env
    cmd = [os.environ.get("LAA_MACBOOK_BUILD", "laa-macbook-build"), "dispatch", "--src", str(REPO),
           "--name", label, "--cache-key", "hermes-conduit", "--scheme", SCHEME,
           "--clean-retry-exit", str(BUILD_FAILURE), "--out", str(out), "--cmd", shlex.join(worker)]
    if (packages / "workspace-state.json").is_file():
        cmd += ["--packages", str(packages)]
    for pattern in (".deriveddata*", "/build", "node_modules", "/.lab-suite.lock", ".env", ".env.*", ".netrc",
                    "*.p8", "*.p12", "*.pfx", "*.mobileprovision", "*.keychain*"):
        cmd += ["--exclude", pattern]
    if out.is_relative_to(REPO):
        cmd += ["--exclude", f"/{out.relative_to(REPO)}"]
    return cmd, route_env


def cmd_run(args):
    suite = suites()[args.suite]
    if args._worker_source is not None:
        return cmd_worker(args, suite)
    if not args.out:
        raise RuntimeError("run requires --out")
    out = Path(args.out).resolve()
    if out == REPO or REPO.is_relative_to(out):
        raise RuntimeError("--out must be a result directory, not the source tree or an ancestor")
    for ident in args.only:
        if not ONLY_RE.fullmatch(ident):
            raise RuntimeError(f"invalid --only selector: {ident}; expected Target/Class[/test]")
        if ident.split("/")[1] in suite.get("exclude_classes", {}):
            raise RuntimeError(f"cannot run excluded class in {args.suite}: {ident}")
    planned = list(test_phases(args, suite))
    if args.only and {o.split("/")[0] for o in args.only} != {target for _, target in planned}:
        raise RuntimeError("--only includes a target outside the requested test phase")
    if args.dry_run:
        cmd, route_env = route(args, suite, out, {})
        print(json.dumps({"host": args.host, "command": cmd, "env": route_env, "spec": suite["spec"],
                          "build": "build-for-testing (once); use the resulting .xctestrun", "unitBatchSize": UNIT_BATCH,
                          "simulator": PHONE_NAME, "batchBasis": "source estimate; actual batches use the built inventory",
                          "batches": {kind: batches(suite, kind, args.only) for kind, _ in planned}}, indent=2))
        return 0
    if os.environ.get("LAA_BUILD_SLOT_HELD") == "1":
        raise RuntimeError("run suite.py outside the build slot; the selected route acquires it")
    if out.is_dir() and any(RESULT_RE.fullmatch(p.name) or p.suffix == ".xcresult" for p in out.iterdir()):
        raise RuntimeError(f"use a fresh --out directory to keep previous evidence: {out}")

    # Lock the checkout across the local run or source sync. The routed worker
    # already owns the host slot and must never acquire it again.
    with (REPO / ".lab-suite.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(f"another suite run holds {REPO}/.lab-suite.lock; use a separate worktree") from None
        git_env = env({"GIT_OPTIONAL_LOCKS": "0"})
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, env=git_env, text=True).strip()
        dirty = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], cwd=REPO, env=git_env, text=True)
        cmd, route_env = route(args, suite, out, {"sha": head, "dirty": bool(dirty)})
        with subprocess.Popen(cmd, cwd=REPO, env=env(route_env)) as child:
            try:
                rc = child.wait()
            except KeyboardInterrupt:
                # The terminal also interrupts the child. Let it clean up
                # while holding the slot; subprocess.run would kill it early.
                child.wait()
                return 130
    return rc if rc >= 0 else 128 - rc


def cmd_worker(args, suite):
    host = os.environ.get("LAA_MB_HOST")
    if host not in ("mini", "macbook") or (host == "mini" and os.environ.get("LAA_BUILD_SLOT_HELD") != "1"):
        raise RuntimeError("worker requires a routed build slot")
    if Path(os.environ["LAA_MB_SRC"]).resolve() != REPO:
        raise RuntimeError("routed source does not match suite.py's checkout")
    out, derived, packages = (Path(os.environ[k]).resolve() for k in ("LAA_MB_OUT", "LAA_MB_DD", "LAA_MB_PACKAGES"))
    out.mkdir(parents=True, exist_ok=True)
    args.out = out
    meta = dict(json.loads(args._worker_source), suite=args.suite, spec=suite["spec"], host=host,
                started=time.strftime("%Y-%m-%dT%H:%M:%S%z"), only=args.only, phases={})
    sim = Simulator(out)

    def record():
        (out / "run.json").write_text(json.dumps(meta, indent=2))

    def phase(name, only, test_env=None, reset=False):
        """Repeat once only if no real test ran; keep the first result as evidence."""
        bundle, log = out / f"{name}.xcresult", out / f"{name}.log"
        for attempt in (1, 2):
            if reset or attempt == 2:
                sim.start(erase=not args.no_erase)
            rc = run_tests(sim, xctestrun, only, log, bundle, test_env)
            did_run = ran(bundle)
            if did_run or attempt == 2:
                break
            meta.setdefault("retried", {})[name] = f"exit {rc}, no test ran"
            if bundle.exists():
                bundle.rename(f"{bundle}.attempt1")
        if not did_run:
            meta.setdefault("noTestsRan", []).append(name)
        meta["phases"][name] = rc
        record()

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        rc, xctestrun = build_for_testing(suite, sim, derived, packages, out)
        meta["phases"]["build"] = rc
        record()
        if rc:
            print(f"build-for-testing failed ({rc}); log: {out / 'build.log'}", file=sys.stderr)
            return BUILD_FAILURE if rc > 0 else 128 - rc
        for kind, target in test_phases(args, suite):
            sim.start(erase=not sim.owned and not args.no_erase)
            enumerate_tests(sim, xctestrun, out, target)
            selection = batches(suite, kind, args.only, out)
            if not selection:
                raise RuntimeError(f"no {kind} batches selected from {target}")
            if args.only:
                tests = set(inventory(out, target))
                available = tests | {ident.rsplit("/", 1)[0] for ident in tests}
                missing = [ident for ident in args.only if ident.startswith(target + "/")
                           and ident.removesuffix("()") not in available]
                if missing:
                    raise RuntimeError(f"--only selectors missing from built inventory: {', '.join(missing)}")
            fixture = start_fixtures(suite, out, sim.udid) if kind == "ui" else None
            test_env = fixture[-1] if fixture else None
            try:
                for i, only in enumerate(selection):
                    phase(f"{kind}-{i}", only, test_env, reset=kind == "ui")
                if not args.no_rerun:
                    cmd_parse(args)
                    ids = unexpected(args.suite, load(out), target)
                    if 0 < len(ids) <= RERUN_LIMIT:
                        meta.setdefault("rerun", {})[kind] = ids
                        phase(f"rerun-{kind}", [f"-only-testing:{i}" for i in ids], test_env, reset=True)
            finally:
                stop_fixtures(fixture)
        cmd_parse(args)
    finally:
        try:
            sim.stop()
        finally:
            meta["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
            record()
    print(json.dumps(meta["phases"]))
    return 1 if meta.get("noTestsRan") else 0


def fingerprint(message):
    """Stable across runs: numbers, addresses, paths and long quoted text are folded away."""
    text = re.sub(r"0x[0-9a-fA-F]+", "H", message)
    text = re.sub(r"/[\w./@+-]*/([\w.+-]+\.swift)", r"\1", text)
    text = re.sub(r"\d+(\.\d+)?", "N", text)
    text = re.sub(r"\s+", " ", text).strip()[:400]
    return hashlib.sha1(text.encode()).hexdigest()[:12]


def walk(node, target, found, rerun=False):
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
        # A test that ran in two bundles keeps the later result; a pass that
        # needed the isolated rerun keeps what failed first.
        before = found.get(ident)
        if rerun and before and result == "Passed" and (before["result"] == "Failed" or before.get("rerun")):
            entry["rerun"] = before.get("rerun") or {k: before.get(k) for k in ("result", "fingerprint", "message")}
        found[ident] = entry
        return
    for child in node.get("children", []):
        walk(child, target, found, rerun)


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
            walk(node, "", found, rerun=bundle.name.startswith("rerun-"))
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
        elif bad and entry["result"] == "Failed" and listed.get("fingerprint") != entry["fingerprint"]:
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
    reruns = {ident: e["rerun"] for ident, e in tests.items() if e.get("rerun")}
    print(f"{args.suite}: {counts}; listed exceptions {len(known)}; problems {len(problems)}; passed only on rerun {len(reruns)}")
    for line in problems:
        print("  " + line)
    for ident, first in reruns.items():
        print(f"  PASSED ONLY ON RERUN (record it; fix it if it repeats): {ident} first [{first.get('fingerprint')}] {(first.get('message') or '')[:160]}")
    return 1 if problems else 0


def cmd_seed(args):
    tests = load(args.out)
    known = json.loads((LAB / "known-failures.json").read_text()).get(args.suite, {}) if (LAB / "known-failures.json").exists() else {}
    seed = {ident: {"result": e["result"], "fingerprint": e.get("fingerprint"), "class": "", "reason": "", "message": e.get("message", "")[:200]}
            for ident, e in tests.items() if e["result"] != "Passed" and ident not in known}
    print(json.dumps(seed, indent=1, ensure_ascii=False))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run")
    run.add_argument("suite", choices=suites())
    run.add_argument("--out", help="fresh result directory for this run")
    run.add_argument("--phase", default="all", choices=["all", "build", "unit", "ui"])
    run.add_argument("--host", default="auto", choices=["auto", "macbook", "mini"], help="auto and macbook run on the MacBook only (exit 2 when it is unavailable); mini is an explicit opt-in guarded by memory pressure")
    run.add_argument("--dry-run", action="store_true", help="print routing and batch plan without using a host or writing files")
    run.add_argument("--only", nargs="*", default=[])
    run.add_argument("--no-erase", action="store_true", help="keep the simulator's data (quick reruns while narrowing down; not for a gate)")
    run.add_argument("--no-rerun", action="store_true", help="do not run unexplained failures once more on their own")
    run.add_argument("--_worker-source", help=argparse.SUPPRESS)
    parse = sub.add_parser("parse"); parse.add_argument("out")
    for name in ("check", "seed"):
        p = sub.add_parser(name); p.add_argument("suite"); p.add_argument("out")
        if name == "check":
            p.add_argument("--partial", action="store_true", help="a subset ran: skip the did-not-run checks")
    args = parser.parse_args(argv)
    if args.cmd == "run" and args._worker_source is None and not args.out:
        run.error("the following arguments are required: --out")
    try:
        return {"run": cmd_run, "parse": cmd_parse, "check": cmd_check, "seed": cmd_seed}[args.cmd](args)
    except (RuntimeError, OSError, subprocess.SubprocessError, KeyboardInterrupt) as exc:
        print(f"suite: {exc or 'interrupted'}", file=sys.stderr)
        return 130 if isinstance(exc, KeyboardInterrupt) else 1


if __name__ == "__main__":
    sys.exit(main())
