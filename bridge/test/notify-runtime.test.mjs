import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const script = fileURLToPath(new URL('../src/notify/deliver.py', import.meta.url));

function fixture(t, { activationFails = false, paired = true } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'laa-notify-runtime-'));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const root = join(home, '.local/share/hermes-agent');
  const plugin = join(home, '.hermes/plugins/conduit_push');
  const deps = join(root, 'selected-dependencies');
  mkdirSync(join(root, 'pm'), { recursive: true });
  mkdirSync(plugin, { recursive: true });
  mkdirSync(deps);
  writeFileSync(join(root, 'pm/__init__.py'), '');
  writeFileSync(join(root, 'pm/environments.py'), `import sys
def activate_dependencies(root):
    ${activationFails ? 'raise RuntimeError("unavailable runtime")' : 'sys.path.insert(0, str(root / "selected-dependencies"))'}
`);
  // A plugin dependency unavailable to the bare interpreter. This import
  // fails if deliver.py skips the runtime's committed dependency selection.
  writeFileSync(join(deps, 'notification_crypto_fixture.py'), 'available = True\n');
  writeFileSync(join(plugin, 'client.py'), `from notification_crypto_fixture import available
def load_state():
    return ${paired ? '{"paired": True}' : 'None'}
def send_now(payload, timeout):
    assert available
    assert payload["session_id"] == "laa-bridge:laa://today"
    assert timeout == 15
`);
  return home;
}

function deliver(home) {
  const run = spawnSync('python3', ['-I', script], {
    env: { ...process.env, HOME: home },
    input: JSON.stringify({ type: 'response.ready', session_id: 'laa-bridge:laa://today' }),
    encoding: 'utf8', timeout: 10_000,
  });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(run.stderr, '');
  return JSON.parse(run.stdout);
}

test('notification delivery activates the installed Hermes dependencies before loading the plugin', (t) => {
  assert.deepEqual(deliver(fixture(t)), { delivered: true });
});

test('a runtime activation failure remains undelivered for retry', (t) => {
  assert.deepEqual(deliver(fixture(t, { activationFails: true })),
    { delivered: false, reason: 'delivery_unavailable' });
});

test('runtime activation does not create or bypass a notification pairing', (t) => {
  assert.deepEqual(deliver(fixture(t, { paired: false })),
    { delivered: false, reason: 'not_paired' });
});
