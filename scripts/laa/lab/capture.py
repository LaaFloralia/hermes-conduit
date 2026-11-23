#!/usr/bin/env python3
"""Capture Hortensia from synthetic fixtures; see capture-screens.json for coverage."""
import argparse
from contextlib import ExitStack, contextmanager
import datetime as dt
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen

LAB = Path(__file__).resolve().parent
ROOT = LAB.parents[2]
SLOT = '/Users/laa/hq/harness/build-slot.sh'
DEVELOPER = '/Applications/Xcode.app/Contents/Developer'
PHONE = 'DFFD3966-F54E-4C7A-A161-59201C7EA105'
PHONE_NAME = 'LAA 16 Pro Max (iOS 27.0)'
DERIVED = ROOT / '.deriveddata-capture'
MAC_DERIVED = ROOT / '.deriveddata-macdev'
MAC_SH = ROOT / 'scripts/laa/mac-screens.sh'
SIZES = ('900x600', '1280x820', '1680x1050')
SIGNING = ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM=']
# variant: simctl appearance, simctl content_size, SwiftUI content size, motion, transparency, contrast.
VARIANTS = {
    'light': ('light', 'large', 'large', False, False, False),
    'dark': ('dark', 'large', 'large', False, False, False),
    'long-japanese': ('light', 'large', 'large', False, False, False),
    'text-mid': ('light', 'accessibility-medium', 'accessibility1', False, False, False),
    'text-max': ('light', 'accessibility-extra-extra-extra-large', 'accessibility5', False, False, False),
    'reduce-motion': ('light', 'large', 'large', True, False, False),
    'reduce-transparency': ('light', 'large', 'large', False, True, False),
    'increase-contrast': ('light', 'large', 'large', False, False, True),
}
MAC_VARIANTS = ('light', 'dark', 'long-japanese')
MAC_SECTIONS = {'chats', 'work', 'today', 'brain', 'studio', 'drive', 'usage'}
IDENTIFIER = re.compile(r'[a-z][a-z0-9]*(?:-[a-z0-9]+)*\Z')
PNG = b'\x89PNG\r\n\x1a\n'


class CaptureError(Exception):
    pass


def validate_screens(value):
    if not isinstance(value, list) or not value:
        raise CaptureError('Screen manifest must be a nonempty list')
    seen = set()
    for row in value:
        if not isinstance(row, dict) or not all(isinstance(row.get(k), str) and row[k].strip()
                                                for k in ('id', 'title', 'route', 'fixture')):
            raise CaptureError(f'Screen needs id, title, route and fixture: {row!r}')
        key = row['id']
        if not IDENTIFIER.fullmatch(key) or key in seen:
            raise CaptureError(f'Invalid or duplicate screen ID: {key}')
        seen.add(key)
        if 'mac' in row:
            mac = row['mac']
            if not isinstance(mac, dict) or mac.get('section') not in MAC_SECTIONS:
                raise CaptureError(f'{key}: invalid Mac section')
            launch = mac.get('launch', '')
            if launch and (not isinstance(launch, str) or not IDENTIFIER.fullmatch(launch)):
                raise CaptureError(f'{key}: invalid Mac launch selector')
            observed = mac.get('observe', '')
            if observed and (not isinstance(observed, str) or not re.fullmatch(r'/v1/[a-z/\-]+', observed)):
                raise CaptureError(f'{key}: invalid Mac fixture observation route')
    return value


def selection(value, options, param):
    if value is None:
        return list(options)
    items = value.split(',')
    if len(set(items)) != len(items) or any(item not in options for item in items):
        raise CaptureError(f'{param}: expected distinct values from {", ".join(options)}')
    return items


def matrix(screens, platforms, variants=None):
    return [(platform, variant, row['id'], size)
            for platform in platforms
            for variant in (variants or (VARIANTS if platform == 'iphone' else MAC_VARIANTS))
            if platform == 'iphone' or variant in MAC_VARIANTS
            for row in screens if platform == 'iphone' or 'mac' in row
            for size in (('',) if platform == 'iphone' else SIZES)]


def filename(key):
    platform, variant, screen, size = key
    return f'{platform}/{variant}/{screen}{"@" + size if size else ""}.png'


def png_size(path):
    with path.open('rb') as f:
        data = f.read(24)
    if len(data) != 24 or data[:16] != PNG + b'\0\0\0\rIHDR':
        raise CaptureError(f'Not a PNG: {path}')
    width, height = struct.unpack('>II', data[16:24])
    if not width or not height:
        raise CaptureError(f'Empty PNG: {path}')
    return [width, height]


def now(timestamp=None):
    return (dt.datetime.now(dt.timezone.utc) if timestamp is None else
            dt.datetime.fromtimestamp(timestamp, dt.timezone.utc)).isoformat(timespec='milliseconds')


def image_entry(base, key, sha, timestamp):
    platform, variant, screen, size = key
    rel = filename(key)
    image = base / rel
    return {'screen': screen, 'variant': variant, 'platform': platform, 'size': size or None,
            'path': rel, 'sha256': hashlib.sha256(image.read_bytes()).hexdigest(), 'pixel_size': png_size(image),
            'app_sha': sha, 'simulator': {'name': PHONE_NAME, 'udid': PHONE} if platform == 'iphone' else None,
            'taken_at': now(timestamp)}


def index(base, expected, entries, screens, proof, elapsed):
    keys = [filename(key) for key in expected]
    paths = [entry['path'] for entry in entries]
    missing = set(keys) - set(paths)
    extra = set(paths) - set(keys)
    if missing or extra or len(paths) != len(set(paths)):
        raise CaptureError(f'Incomplete capture (missing={sorted(missing)}, extra={sorted(extra)}, duplicates={len(paths) - len(set(paths))})')
    by_path = {entry['path']: entry for entry in entries}
    ordered = [by_path[key] for key in keys]
    dump(base / 'index.json', {'schema': 1, 'screens': screens, 'images': ordered,
                               'variant_proof': proof, 'wall_seconds': round(elapsed, 2)})
    (base / 'index.html').write_text(contact_sheet(screens, ordered), encoding='utf-8')


def contact_sheet(screens, entries):
    e = html.escape
    lines = ['<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
             '<title>Hortensia Capture</title><style>body{font-family:system-ui}table{border-collapse:collapse}',
             'td,th{border:1px solid;padding:.5em;vertical-align:top;text-align:left}',
             'td img{width:160px;height:auto}th small{display:block;font-weight:normal}</style>',
             '<h1>Hortensia Capture</h1>']
    for platform in dict.fromkeys(row['platform'] for row in entries):
        relevant = [row for row in entries if row['platform'] == platform]
        sizes = dict.fromkeys(row['size'] for row in relevant)
        for size in sizes:
            rows = [row for row in relevant if row['size'] == size]
            variants = list(dict.fromkeys(row['variant'] for row in rows))
            by_key = {(row['screen'], row['variant']): row for row in rows}
            lines.append(f'<h2>{e(platform)} {e(size or "")}</h2><table><thead><tr><th>画面</th>')
            lines.extend(f'<th scope="col">{e(variant)}</th>' for variant in variants)
            lines.append('</tr></thead><tbody>')
            for screen in screens:
                if not any((screen['id'], variant) in by_key for variant in variants):
                    continue
                lines.append(f'<tr><th scope="row">{e(screen["title"])}<small>{e(screen["id"])}</small></th>')
                for variant in variants:
                    row = by_key.get((screen['id'], variant))
                    if row:
                        path = e(row['path'], quote=True)
                        lines.append(f'<td><a href="{path}"><img loading="lazy" src="{path}" alt="{e(screen["title"])}"></a></td>')
                    else:
                        lines.append('<td>—</td>')
                lines.append('</tr>')
            lines.append('</tbody></table>')
    return '\n'.join(lines + ['</html>', ''])


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def safe_env():
    keep = ('PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR', 'LANG', 'LC_ALL', 'SSH_AUTH_SOCK')
    env = {key: os.environ[key] for key in keep if key in os.environ}
    env.update(DEVELOPER_DIR=DEVELOPER, GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='/usr/bin/false')
    # Allow shorter/longer contention policy, never inherit a claimed lock or live opt-ins.
    if 'LAA_BUILD_SLOT_MAX_WAIT' in os.environ:
        env['LAA_BUILD_SLOT_MAX_WAIT'] = os.environ['LAA_BUILD_SLOT_MAX_WAIT']
    return env


def run(command, log, *, env=None, check=True, data=False):
    command = [str(part) for part in command]
    with log.open('a', encoding='utf-8') as f:
        f.write(f'\n$ {" ".join(command)}\n')
        f.flush()
        with subprocess.Popen(command, cwd=ROOT, env=env or safe_env(), text=True,
                              stdout=subprocess.PIPE if data else f, stderr=f, start_new_session=True) as proc:
            try:
                stdout, _ = proc.communicate()
            except KeyboardInterrupt:
                # Forward cancellation only to our own command. In the slot
                # wrapper, _handset restores settings before releasing the lock.
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGTERM)
                proc.wait()
                raise
        if data:
            f.write(stdout)
        f.write(f'\nexit={proc.returncode}\n')
    if check and proc.returncode != 0:
        raise CaptureError(f'Exit {proc.returncode}: {command[0]} {command[1]} — {log}')
    return stdout.strip() if data and proc.returncode == 0 else None


def observe(port, route):
    with urlopen(f'http://127.0.0.1:{port}{route}', timeout=3) as response:
        return json.load(response)


def free_pair():
    for _ in range(20):
        with socket.socket() as one, socket.socket() as two:
            one.bind(('127.0.0.1', 0))
            port = one.getsockname()[1]
            try:
                two.bind(('127.0.0.1', port + 1))
            except (OSError, OverflowError):
                continue
            return port
    raise CaptureError('Could not find a loopback port pair for Work')


@contextmanager
def child(cmd, log, env):
    with log.open('w+', encoding='utf-8') as f:
        proc = subprocess.Popen(cmd, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT, env=env)
        try:
            yield proc
        finally:
            if proc.poll() is None:
                proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


@contextmanager
def fixtures(logs):
    env = safe_env()
    port = free_pair()
    env.update(WORK_FIXTURE_PORT=str(port), WORK_FIXTURE_TASKS='many')
    with ExitStack() as stack:
        work = stack.enter_context(child(['node', 'scripts/laa/work-ui-fixture.mjs'], logs / 'fixture-work.log', env))
        for _ in range(80):
            if work.poll() is not None:
                raise CaptureError(f'Work fixture exited; see {logs / "fixture-work.log"}')
            try:
                if 'served' in observe(port + 1, '/state'):
                    break
            except (OSError, ValueError):
                time.sleep(0.1)
        else:
            raise CaptureError('Work fixture did not become ready')
        proxy_log = logs / 'fixture-capture.log'
        proxy = stack.enter_context(child(['node', str(LAB / 'capture-fixture.mjs'), str(port)], proxy_log, env))
        for _ in range(80):
            if proxy.poll() is not None:
                raise CaptureError(f'Capture fixture exited; see {proxy_log}')
            try:
                ports = json.loads(proxy_log.read_text().splitlines()[0])
                if set(ports) == {'normal', 'empty', 'loading', 'error', 'long'} and all(
                        observe(port, '/lab/health') == {'mode': mode} for mode, port in ports.items()):
                    break
            except (OSError, ValueError, IndexError):
                pass
            time.sleep(0.1)
        else:
            raise CaptureError('Capture fixture did not become ready')
        yield ports


def storage(logs):
    run(['laa-storage-guard', 'status', '--quick'], logs / 'storage.log')
    if shutil.disk_usage(ROOT).free < 80 * (1024 ** 3):
        raise CaptureError('Less than 80 GiB free on the build host')


def bool_text(value):
    return str(value).lower()


def expected_traits(variant):
    theme, _, size, motion, transparency, contrast = VARIANTS[variant]
    return ','.join([theme, size, *map(bool_text, (motion, transparency, contrast, motion, transparency))])


def handset(config):
    """Private, lock-held subprocess; boot, apply and restore only our device."""
    if os.environ.get('LAA_BUILD_SLOT_HELD') != '1':
        raise CaptureError('Simulator lane must hold the shared build slot')
    log = Path(config['log'])
    sim = ['xcrun', 'simctl']
    run([*sim, 'boot', PHONE], log)
    try:
        run([*sim, 'bootstatus', PHONE], log)
        action = config['action']
        dest = f'platform=iOS Simulator,id={PHONE}'
        common = ['xcodebuild', action, '-destination', dest, '-jobs', '4', '-packageAuthorizationProvider', 'netrc']
        if action == 'build-for-testing':
            run([*common, '-project', 'Conduit.xcodeproj', '-scheme', 'Conduit', '-derivedDataPath', DERIVED, *SIGNING], log)
            return
        variant = config['variant']
        color, size, _, motion, trans, contrast = VARIANTS[variant]
        ui = [*sim, 'ui', PHONE]
        defaults = [*sim, 'spawn', PHONE, 'defaults']
        domain = 'com.apple.Accessibility'
        toggles = {'ReduceMotionEnabled': motion, 'ReduceTransparencyEnabled': trans}
        ui_values = {'appearance': color, 'content_size': size, 'increase_contrast': 'enabled' if contrast else 'disabled'}
        original = {key: run([*ui, key], log, data=True) for key in ui_values}
        if any(setting in ('unknown', 'unsupported', '') for setting in original.values()):
            raise CaptureError(f'Cannot restore unreadable simulator settings: {original}')
        prior = {key: run([*defaults, 'read', domain, key], log, check=False, data=True) for key in toggles}
        try:
            for key, wanted in ui_values.items():
                run([*ui, key, wanted], log)
                got = run([*ui, key], log, data=True)
                if got != wanted:
                    raise CaptureError(f'{key}: simctl readback {got!r}, expected {wanted!r}')
            for key, value in toggles.items():
                run([*defaults, 'write', domain, key, '-bool', bool_text(value)], log)
            env = safe_env()
            env.update({f'TEST_RUNNER_{key}': val for key, val in config['test_env'].items()})
            run([*common, '-xctestrun', config['xctestrun'], '-resultBundlePath', config['result'],
                 '-parallel-testing-enabled', 'NO', '-only-testing:ConduitUITests/LAALabCaptureUITests/testCapture'], log, env=env)
        finally:
            errors = []
            for key, value in original.items():
                try:
                    run([*ui, key, value], log)
                    if run([*ui, key], log, data=True) != value:
                        raise CaptureError(f'Could not verify restoration of {key}')
                except CaptureError as exc:
                    errors.append(str(exc))
            for key, value in prior.items():
                try:
                    if value is None:
                        run([*defaults, 'delete', domain, key], log)
                    else:
                        run([*defaults, 'write', domain, key, '-bool', bool_text(value in ('1', 'true', 'YES'))], log)
                    if run([*defaults, 'read', domain, key], log, check=False, data=True) != value:
                        raise CaptureError(f'Could not verify restoration of {key}')
                except CaptureError as exc:
                    errors.append(str(exc))
            if errors:
                raise CaptureError('; '.join(errors))
    finally:
        run([*sim, 'shutdown', PHONE], log)


def in_slot(config, work, log):
    job = work / 'phone-job.json'
    dump(job, config)
    run(['/bin/bash', SLOT, sys.executable, __file__, '_handset', job], log)


def attachments(bundle, dest, logs):
    tool = ['xcrun', 'xcresulttool']
    summary = json.loads(run([*tool, 'get', 'test-results', 'summary', '--path', bundle, '--compact'], logs, data=True))
    counts = tuple(summary[key] for key in ('passedTests', 'failedTests', 'skippedTests'))
    print(f'{bundle.stem}: passed={counts[0]} failed={counts[1]} skipped={counts[2]}', flush=True)
    if counts != (1, 0, 0):
        raise CaptureError(f'{bundle.stem}: unexpected result counts {counts}')
    # One call per xcresult: parallel exports race the result index.
    run([*tool, 'export', 'attachments', '--path', bundle, '--output-path', dest], logs)
    manifest = json.loads((dest / 'manifest.json').read_text())
    for test in manifest:
        yield from test['attachments']


def phone_capture(entries, proof, work, logs, sha, cells, ports):
    run(['xcodegen', 'generate', '--spec', 'project-laa.yml'], logs / 'iphone-xcodegen.log')
    in_slot({'action': 'build-for-testing', 'log': str(logs / 'iphone-build.log')}, work, logs / 'slot.log')
    xctestruns = list((DERIVED / 'Build/Products').glob('Conduit_*iphonesimulator*.xctestrun'))
    if len(xctestruns) != 1:
        raise CaptureError(f'Expected exactly one iPhone .xctestrun; got {xctestruns}')
    for variant in dict.fromkeys(key[1] for key in cells):
        selected = {key[2]: key for key in cells if key[1] == variant}
        observed, captured = None, set()
        bundle = work / f'{variant}.xcresult'
        exported = work / f'export-{variant}'
        log = logs / f'iphone-{variant}.log'
        expected = expected_traits(variant)
        test_env = {'LAA_LAB_SCREENS': ','.join(selected), 'LAA_LAB_TRAITS': expected,
                    'LAA_LAB_LONG_JAPANESE': '1' if variant == 'long-japanese' else '0',
                    'LAA_LAB_PORT': str(ports['long' if variant == 'long-japanese' else 'normal']),
                    **{f'LAA_LAB_PORT_{mode.upper()}': str(ports[mode]) for mode in ('empty', 'loading', 'error')}}
        config = {'action': 'test-without-building', 'xctestrun': str(xctestruns[0]), 'result': str(bundle),
                  'variant': variant, 'test_env': test_env, 'log': str(log)}
        try:
            in_slot(config, work, logs / 'slot.log')
            for attachment in attachments(bundle, exported, log):
                name = attachment['suggestedHumanReadableName']
                match = re.match(r'^lab-(?P<id>[a-z][a-z0-9-]*)(?=[^a-z0-9-]|$)', name)
                if not match:
                    continue  # XCTest's automatic screenshots/logs are not captures.
                image = exported / attachment['exportedFileName']
                key = match['id']
                if key == 'traits':
                    if observed is not None:
                        raise CaptureError(f'{variant}: duplicate trait proof')
                    observed = image.read_text().strip()
                    continue
                if key not in selected or key in captured:
                    raise CaptureError(f'{variant}: unexpected or duplicate attachment {name}')
                path = work / filename(selected[key])
                path.parent.mkdir(parents=True, exist_ok=True)
                image.replace(path)
                entry = image_entry(work, selected[key], sha, attachment.get('timestamp'))
                if entry['pixel_size'] != [1320, 2868]:
                    raise CaptureError(f'Not a 440×956 pt @3× screenshot: {entry["path"]} ({entry["pixel_size"]})')
                entries.append(entry)
                captured.add(key)
            if set(selected) != captured or observed != expected:
                raise CaptureError(f'{variant}: missing {sorted(set(selected)-captured)}, traits={observed!r}, expected={expected!r}')
            proof[f'iphone/{variant}'] = {'traits': observed, 'source': 'SwiftUI environment + UIKit accessibility flags'}
        finally:
            for path in (bundle, exported):
                if path.exists():
                    shutil.rmtree(path)


def mac_capture(entries, proof, work, logs, sha, cells, ports, screens):
    base = work / 'mac-raw'
    run(['/bin/bash', MAC_SH, '--build-only', '--out', base, '--build-log', logs / 'mac-build.log'], logs / 'mac.log')
    rows = {row['id']: row for row in screens}
    for variant, screen in dict.fromkeys((key[1], key[2]) for key in cells):
        mac = rows[screen]['mac']
        settings = ['-LAA_LAB_CAPTURE', '-LAA_UI_TEST_ISOLATED_BRIDGE', '-LAA_UI_TEST_CLEAR_WORK_STORE',
                    '-CONDUIT_UI_TEST_CONNECTED_DASHBOARD', 'https://lab-capture.invalid']
        mode = 'long' if variant == 'long-japanese' else 'normal'
        port = ports[mode]
        settings += ['-LAA_UI_TEST_WORK_FIXTURE_PORT', str(port)]
        if mode == 'long':
            settings += ['-LAA_LAB_LONG_JAPANESE']
        if mac['section'] == 'work':
            settings += ['-laa-work-section', mac['launch']]
        elif mac.get('launch') == 'chat':
            settings += ['-LAA_MAC_CHAT_FIXTURE', '-LAA_V2_CHAT_FIXTURE', 'rich', '-LAA_CAPTURE_SURFACE', 'chat']
        elif mac.get('launch') == 'brain':
            settings += ['-laa-brain-fixture', 'normal']
        theme = 'dark' if variant == 'dark' else 'light'
        log = logs / 'mac.log'
        owner = f'{screen}-{variant}'
        run(['/bin/bash', MAC_SH, '--skip-build', '--out', base, '--owner', owner, '--sections', mac['section'],
             '--sizes', ','.join(SIZES), '--schemes', theme, '--settle', '1.5',
             '--app-args', ' '.join(settings), '--app-env', 'CONDUIT_UITEST=1'], log)
        for size in SIZES:
            raw = base / owner / f'{mac["section"]}-{size}-{theme}.png'
            if not raw.is_file():
                raise CaptureError(f'Missing Mac real-window screenshot: {raw.name}; {log}')
            key = ('mac', variant, screen, size)
            dest = work / filename(key)
            dest.parent.mkdir(parents=True, exist_ok=True)
            raw.replace(dest)
            entries.append(image_entry(work, key, sha, dest.stat().st_mtime))
        if mac.get('observe') and mac['observe'] not in observe(port, '/lab/observed'):
            raise CaptureError(f'{screen}/{variant}: Mac fixture never served {mac["observe"]}')
        proof[f'mac/{variant}'] = {'window': 'screencapture -l (real macdev window)', 'appearance': theme,
                                   'fixture': mode, 'content_sizes': SIZES}


def capture(args):
    start = time.monotonic()
    screens = validate_screens(json.loads((LAB / 'capture-screens.json').read_text()))
    wanted = selection(args.screens, {row['id']: row for row in screens}, '--screens')
    screens = [row for row in screens if row['id'] in wanted]
    platforms = selection(args.platform, ('iphone', 'mac'), '--platform')
    variants = selection(args.variants, VARIANTS, '--variants') if args.variants is not None else None
    expected = matrix(screens, platforms, variants)
    if any(not any(cell[0] == p for cell in expected) for p in platforms):
        raise CaptureError('Requested platform has no matching screens/variants (Mac: light,dark,long-japanese)')
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any((out / name).exists() for name in ('index.json', 'index.html', 'iphone', 'mac', 'logs')):
        raise CaptureError('Output already contains a capture or its logs; use a fresh --out')
    logs = out / 'logs'
    logs.mkdir()
    storage(logs)
    sha = run(['git', 'rev-parse', 'HEAD'], logs / 'git.log', data=True)
    run(['git', 'status', '--short', '--untracked-files=no'], logs / 'git.log')
    # Project generation and DerivedData are worktree-local and must not race
    # a second invocation in the same worktree, even outside the build slot.
    lock_path = ROOT / 'build/capture.lock'
    lock_path.parent.mkdir(exist_ok=True)
    with lock_path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise CaptureError(f'Capture already running in {ROOT}') from exc
        try:
            with tempfile.TemporaryDirectory(prefix='.capture-', dir=out) as tmp, fixtures(logs) as ports:
                work = Path(tmp)
                entries, proof = [], {}
                if 'iphone' in platforms:
                    phone_capture(entries, proof, work, logs, sha, [key for key in expected if key[0] == 'iphone'], ports)
                if 'mac' in platforms:
                    mac_capture(entries, proof, work, logs, sha, [key for key in expected if key[0] == 'mac'], ports, screens)
                elapsed = time.monotonic() - start
                index(work, expected, entries, screens, proof, elapsed)
                for name in [*platforms, 'index.html', 'index.json']:
                    (work / name).replace(out / name)
            print(f'{len(entries)} PNGs, {elapsed:.1f}s; {out / "index.html"}', flush=True)
        finally:
            if not args.keep_build:
                if 'iphone' in platforms and DERIVED.exists():
                    shutil.rmtree(DERIVED)
                if 'mac' in platforms and MAC_DERIVED.exists():
                    shutil.rmtree(MAC_DERIVED)
    return 0


def load_index(base):
    base = base.resolve()
    doc = json.loads((base / 'index.json').read_text())
    if doc.get('schema') != 1:
        raise CaptureError(f'Unknown index schema: {base}')
    by_key = {}
    for row in doc['images']:
        key = (row['platform'], row['variant'], row['screen'], row['size'] or '')
        if (key in by_key or key[0] not in ('iphone', 'mac') or key[1] not in VARIANTS
                or not IDENTIFIER.fullmatch(key[2]) or key[3] not in ('', *SIZES)
                or row['path'] != filename(key)):
            raise CaptureError(f'Invalid index entry: {row}')
        file = base / row['path']
        if not file.is_file() or not file.resolve().is_relative_to(base):
            raise CaptureError(f'File is missing from its capture directory: {file}')
        if hashlib.sha256(file.read_bytes()).hexdigest() != row['sha256'] or png_size(file) != row['pixel_size']:
            raise CaptureError(f'File differs from index: {file}')
        by_key[key] = row
    return by_key


def compare(before, after, pixel_ratios):
    left, right = load_index(before), load_index(after)
    added, missing = sorted(right.keys() - left.keys()), sorted(left.keys() - right.keys())
    changed = [key for key in sorted(left.keys() & right.keys()) if left[key]['sha256'] != right[key]['sha256']]
    ratios = pixel_ratios([(before / left[key]['path'], after / right[key]['path']) for key in changed]) if changed else []
    if len(ratios) != len(changed):
        raise CaptureError('Pixel decoder returned the wrong number of results')
    differences = [{'path': filename(key), 'changed_pixel_ratio': ratio}
                   for key, ratio in zip(changed, ratios) if ratio > 0]
    return {'changed': differences, 'added': [filename(key) for key in added],
            'missing': [filename(key) for key in missing], 'unchanged': len(left.keys() & right.keys()) - len(differences)}


def coregraphics_ratios(pairs):
    with tempfile.TemporaryDirectory(prefix='laa-capture-pixels-') as tmp:
        helper = str(Path(tmp) / 'pixels')
        compiler = subprocess.run(['xcrun', 'swiftc', '-O', str(LAB / 'capture-pixels.swift'), '-o', helper],
                                  env=safe_env(), text=True, capture_output=True)
        if compiler.returncode:
            raise CaptureError(f'Could not compile pixel decoder: {compiler.stderr.strip()}')
        r = subprocess.run([helper], env=safe_env(), text=True, capture_output=True,
                           input=json.dumps([[str(a), str(b)] for a, b in pairs]))
    if r.returncode:
        raise CaptureError(f'Pixel decoder failed ({r.returncode}): {r.stderr.strip()}')
    return json.loads(r.stdout)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ['_handset']:
        handset(json.loads(Path(argv[1]).read_text()))
        return 0
    if argv[:1] == ['diff']:
        parser = argparse.ArgumentParser(prog='capture.py diff', description='List changed, added and missing capture cells')
        parser.add_argument('before', type=Path)
        parser.add_argument('after', type=Path)
        args = parser.parse_args(argv[1:])
        print(json.dumps(compare(args.before.resolve(), args.after.resolve(), coregraphics_ratios), indent=2))
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    parser.add_argument('--platform', help='iphone,mac (default: both)')
    parser.add_argument('--variants', help=','.join(VARIANTS))
    parser.add_argument('--screens', help='comma-separated IDs in capture-screens.json')
    parser.add_argument('--keep-build', action='store_true', help='retain local DerivedData for an iterative run')
    return capture(parser.parse_args(argv))


def interrupted(signum, _frame):
    raise KeyboardInterrupt(f'Received signal {signum}')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except (CaptureError, OSError, ValueError, KeyError) as exc:
        print(f'capture: {exc}', file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('capture: interrupted', file=sys.stderr)
        sys.exit(130)
