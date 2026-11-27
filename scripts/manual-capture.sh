#!/bin/bash
# Build the existing ad-hoc Catalyst app and run the Mac-only lab fixture lane.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
state="$HOME/.local/state/laa-manuals"
out="$state/hortensia/captures"
only=
while (( $# )); do
    case "$1" in
        --out|--only) [[ -n ${2:-} && $2 != --* ]] || exit 2
            if [[ $1 == --out ]]; then out=$2; else only=$2; fi; shift 2 ;;
        *) echo "Usage: $0 [--out DIR] [--only id,id]" >&2; exit 2 ;;
    esac
done
mkdir -p "$out" "$state"
out=$(cd "$out" && pwd)
# The underlying script uses worktree-local DerivedData and a temporary spec.
worktree_lock="$state/hortensia-build-$(printf %s "$root" | shasum | cut -c1-40).lock"
/usr/bin/lockf -k "$worktree_lock" python3 - "$root" "$out" "$only" "$state/capture.lock" <<'PY'
from datetime import datetime, timezone
from hashlib import sha256
from pathlib import Path
from struct import unpack
from tempfile import TemporaryDirectory
import json, re, runpy, subprocess, sys

root, out = map(Path, sys.argv[1:3])
source = root / 'Conduit/LAA/Mac/LAAMacSection.swift'
sections = re.findall(r'^    case ([a-z]+)$', source.read_text(), re.M)
choices = sections + ['chats-narrow']
ids = list(dict.fromkeys(sys.argv[3].split(','))) if sys.argv[3] else choices
if not ids or any(i not in choices for i in ids): sys.exit('Unknown screen ID; choose from ' + ','.join(choices))
sha = subprocess.check_output(['git', '-C', root, 'rev-parse', 'HEAD'], text=True).strip()
lab = runpy.run_path(str(root / 'scripts/laa/lab/capture.py'))
mac = root / 'scripts/laa/mac-screens.sh'
with TemporaryDirectory(prefix='.capture.', dir=out) as temp:
    stage = Path(temp)
    build_cmd = '''
        set -e
        export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false LAA_MAC_SCREENS_BUILD_DRIVER=/usr/bin/env
        "$LAA_MB_SRC/scripts/laa/mac-screens.sh" --out "$LAA_MB_OUT/raw" --build-only --build-log "$LAA_MB_OUT/build.log"
        ditto "$LAA_MB_SRC/.deriveddata-macdev/Build/Products/Debug-maccatalyst/Conduit.app" "$LAA_MB_OUT/Conduit.app"
    '''
    artifact = stage / 'artifact'
    result = subprocess.run(['laa-macbook-build', 'dispatch', '--src', root, '--name', 'manual-capture-hortensia',
                             '--cache-key', 'hermes-conduit', '--scheme', 'HortensiaManual', '--mb-wait', '1200', '--fallback-mini',
                             '--exclude', '.deriveddata*', '--exclude', 'build/', '--out', artifact,
                             '--cmd', build_cmd], env=lab['safe_env']())
    if (artifact / 'build.log').exists():
        sys.stdout.write((artifact / 'build.log').read_text(errors='replace'))
        sys.stdout.flush()
    result.check_returncode()
    app = artifact / 'Conduit.app'
    signature = subprocess.check_output(['/usr/bin/codesign', '-dv', app], stderr=subprocess.STDOUT, text=True)
    bundle_id = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier',
                                         app / 'Contents/Info.plist'], text=True).strip()
    if 'Signature=adhoc' not in signature or bundle_id != 'com.laa-inc.laa.macdev':
        sys.exit('Expected the isolated ad-hoc macdev app')
    target = root / '.deriveddata-macdev/Build/Products/Debug-maccatalyst/Conduit.app'
    subprocess.run(['/usr/bin/ditto', app, target], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', target], check=True)
    files = []
    with lab['fixtures'](stage) as ports:
        port = ports['normal']
        common = (f'-LAA_LAB_CAPTURE -LAA_UI_TEST_ISOLATED_BRIDGE -LAA_UI_TEST_CLEAR_WORK_STORE '
                  f'-CONDUIT_UI_TEST_CONNECTED_DASHBOARD https://lab-capture.invalid -LAA_UI_TEST_WORK_FIXTURE_PORT {port}')
        chat = ' -LAA_MAC_CHAT_FIXTURE -LAA_V2_CHAT_FIXTURE rich -LAA_CAPTURE_SURFACE chat'
        for screen in ids:
            section = 'chats' if screen == 'chats-narrow' else screen
            size = '900x600' if screen == 'chats-narrow' else '1280x820'
            extra = chat if section == 'chats' else ' -laa-brain-fixture normal' if section == 'brain' else ''
            subprocess.run(['/usr/bin/lockf', '-k', sys.argv[4], mac, '--skip-build', '--out', stage,
                            '--owner', screen, '--sections', section, '--sizes', size, '--schemes', 'light,dark',
                            '--settle', '1.5', '--lab-fixture-mode', 'normal', '--app-args', common + extra,
                            '--app-env', f'CONDUIT_UITEST=1 LAA_BRIDGE_DEFAULT_ADDRESS=http://127.0.0.1:{port}'],
                           env=lab['safe_env'](), check=True)
            for variant in ('light', 'dark'):
                path = stage / screen / f'{section}-{size}-{variant}.png'
                name = f'{screen}-{variant}.png'
                if not path.is_file(): sys.exit(f'Missing shot: {name}')
                data = path.read_bytes()
                if len(data) < 24 or data[:16] != b'\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR': sys.exit(f'Invalid PNG: {name}')
                width, height = unpack('>II', data[16:24])
                subprocess.run(['/usr/bin/sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path], check=True, stdout=subprocess.DEVNULL)
                files.append(dict(name=name, sha256=sha256(data).hexdigest(), width=width, height=height))
                path.replace(stage / name)
    if subprocess.check_output(['git', '-C', root, 'rev-parse', 'HEAD'], text=True).strip() != sha:
        sys.exit('HEAD changed during capture')
    index = stage / 'captures.json'
    index.write_text(json.dumps(dict(schema='laa.manual-captures.v1', appId='hortensia', gitSha=sha,
                                     generatedAt=datetime.now(timezone.utc).isoformat(), files=files), indent=2)+'\n')
    for entry in files: (stage / entry['name']).replace(out / entry['name'])
    index.replace(out / index.name)
PY
