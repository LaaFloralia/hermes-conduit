import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const helper = join(dirname(fileURLToPath(import.meta.url)), '..', 'scripts', 'preserve-plist-env.py');

function plist(env) {
  const entries = Object.entries(env)
    .map(([key, value]) => `\t\t<key>${key}</key>\n\t\t<string>${value}</string>`)
    .join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>EnvironmentVariables</key>
\t<dict>
${entries}
\t</dict>
</dict>
</plist>
`;
}

function environment(path) {
  const json = execFileSync('plutil', ['-convert', 'json', '-o', '-', path], { encoding: 'utf8' });
  return JSON.parse(json).EnvironmentVariables;
}

function workspace(t) {
  const dir = mkdtempSync(join(tmpdir(), 'laa-plist-env-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test('a reinstall keeps the three opt-in settings and nothing else from the old plist', (t) => {
  const dir = workspace(t);
  const previous = join(dir, 'previous.plist');
  const next = join(dir, 'next.plist');
  writeFileSync(previous, plist({
    HOME: '/Users/someone',
    LAA_BRIDGE_PORT: '9137',
    LAA_LINEAR_PERSONAL_TOKEN_HELPER: '/Users/someone/.local/bin/laa-linear-key',
    LAA_LINEAR_PERSONAL_VIEWER_ID: 'viewer-1',
    LAA_GOOGLE_REMINDERS_ENABLED: '1',
    LAA_SOMETHING_ELSE: 'keep-me-out',
  }));
  writeFileSync(next, plist({ HOME: '/Users/someone', LAA_BRIDGE_PORT: '9137', PATH: '/usr/bin:/bin' }));

  execFileSync('python3', [helper, previous, next]);

  const env = environment(next);
  assert.equal(env.LAA_LINEAR_PERSONAL_TOKEN_HELPER, '/Users/someone/.local/bin/laa-linear-key');
  assert.equal(env.LAA_LINEAR_PERSONAL_VIEWER_ID, 'viewer-1');
  assert.equal(env.LAA_GOOGLE_REMINDERS_ENABLED, '1');
  assert.equal(env.LAA_SOMETHING_ELSE, undefined, 'only the three carried keys survive');
  assert.equal(env.PATH, '/usr/bin:/bin', 'the template keeps its own values');
});

test('a fresh install gains none of the opt-in settings', (t) => {
  const dir = workspace(t);
  const next = join(dir, 'next.plist');
  writeFileSync(next, plist({ HOME: '/Users/someone', PATH: '/usr/bin:/bin' }));
  const before = readFileSync(next, 'utf8');

  execFileSync('python3', [helper, join(dir, 'missing.plist'), next]);

  assert.equal(readFileSync(next, 'utf8'), before);
  const env = environment(next);
  assert.equal(env.LAA_LINEAR_PERSONAL_TOKEN_HELPER, undefined);
  assert.equal(env.LAA_LINEAR_PERSONAL_VIEWER_ID, undefined);
  assert.equal(env.LAA_GOOGLE_REMINDERS_ENABLED, undefined, 'reminders stay off until an operator enables them');
});

test('an old plist without the settings carries nothing', (t) => {
  const dir = workspace(t);
  const previous = join(dir, 'previous.plist');
  const next = join(dir, 'next.plist');
  writeFileSync(previous, plist({ HOME: '/Users/someone', LAA_SOMETHING_ELSE: 'x' }));
  writeFileSync(next, plist({ HOME: '/Users/someone' }));
  const before = readFileSync(next, 'utf8');

  execFileSync('python3', [helper, previous, next]);

  assert.equal(readFileSync(next, 'utf8'), before);
});
