import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const bridgeDir = join(dirname(fileURLToPath(import.meta.url)), '..');
const scripts = join(bridgeDir, 'scripts');
const helper = join(scripts, 'preserve-plist-env.py');
const renderer = join(scripts, 'install-plist.sh');
const template = join(dirname(fileURLToPath(import.meta.url)), '..', 'launchd', 'com.laa.bridge.plist');

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

test('a live plist that cannot be parsed stops the install and stays as it was', (t) => {
  const dir = workspace(t);
  const previous = join(dir, 'previous.plist');
  const next = join(dir, 'next.plist');
  writeFileSync(previous, 'not a plist at all');
  writeFileSync(next, plist({ HOME: '/Users/someone' }));
  const live = readFileSync(previous);
  const rendered = readFileSync(next);

  const result = spawnSync('python3', [helper, previous, next]);

  assert.notEqual(result.status, 0, 'a broken live plist is a failure, not a silent skip');
  assert.deepEqual(readFileSync(previous), live, 'the live plist keeps its bytes');
  assert.deepEqual(readFileSync(next), rendered, 'the rendered file is untouched');
  assert.equal(result.stdout.toString(), '', 'values are never printed');
});

test('install-plist.sh keeps the live plist bytes when the previous plist is unreadable', (t) => {
  const dir = workspace(t);
  const live = join(dir, 'com.laa.bridge.plist');
  writeFileSync(live, 'not a plist at all');
  const original = readFileSync(live);

  const result = spawnSync('sh', [renderer, template, live, '/opt/homebrew/bin/node', bridgeDir, join(dir, 'state'), '9137', '/Users/someone']);

  assert.notEqual(result.status, 0);
  assert.deepEqual(readFileSync(live), original, 'a failed render never replaces the live plist');
  assert.deepEqual(readdirSync(dir).sort(), ['com.laa.bridge.plist'], 'no temporary file is left behind');
});

test('install-plist.sh renders a fresh plist without enabling the opt-in settings', (t) => {
  const dir = workspace(t);
  const live = join(dir, 'com.laa.bridge.plist');

  execFileSync('sh', [renderer, template, live, '/opt/homebrew/bin/node', bridgeDir, join(dir, 'state'), '9137', '/Users/someone']);

  const env = environment(live);
  assert.equal(env.LAA_BRIDGE_PORT, '9137');
  assert.equal(env.LAA_GOOGLE_REMINDERS_ENABLED, undefined);
  assert.deepEqual(readdirSync(dir).sort(), ['com.laa.bridge.plist']);
});

test('install-plist.sh carries the three settings from the live plist it replaces', (t) => {
  const dir = workspace(t);
  const live = join(dir, 'com.laa.bridge.plist');
  writeFileSync(live, plist({
    HOME: '/Users/someone',
    LAA_LINEAR_PERSONAL_TOKEN_HELPER: '/Users/someone/.local/bin/laa-linear-key',
    LAA_LINEAR_PERSONAL_VIEWER_ID: 'viewer-1',
    LAA_GOOGLE_REMINDERS_ENABLED: '1',
    LAA_SOMETHING_ELSE: 'drop-me',
  }));

  execFileSync('sh', [renderer, template, live, '/opt/homebrew/bin/node', bridgeDir, join(dir, 'state'), '9137', '/Users/someone']);

  const env = environment(live);
  assert.equal(env.LAA_LINEAR_PERSONAL_TOKEN_HELPER, '/Users/someone/.local/bin/laa-linear-key');
  assert.equal(env.LAA_LINEAR_PERSONAL_VIEWER_ID, 'viewer-1');
  assert.equal(env.LAA_GOOGLE_REMINDERS_ENABLED, '1');
  assert.equal(env.LAA_SOMETHING_ELSE, undefined);
  assert.equal(env.LAA_BRIDGE_PORT, '9137', 'the template still supplies its own values');
});

test('a malformed value is never echoed, and the live plist keeps its bytes', (t) => {
  const dir = workspace(t);
  const live = join(dir, 'com.laa.bridge.plist');
  const marker = 'SECRET-MARKER-12345';
  writeFileSync(live, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>EnvironmentVariables</key>
\t<dict>
\t\t<key>LAA_GOOGLE_REMINDERS_ENABLED</key>
\t\t<integer>${marker}</integer>
\t</dict>
</dict>
</plist>
`);
  const original = readFileSync(live);
  const rendered = join(dir, 'rendered.plist');
  writeFileSync(rendered, plist({ HOME: '/Users/someone' }));

  const result = spawnSync('python3', [helper, live, rendered]);

  assert.notEqual(result.status, 0);
  assert.deepEqual(readFileSync(live), original, 'the live plist keeps its bytes');
  assert.doesNotMatch(result.stdout.toString(), new RegExp(marker));
  assert.doesNotMatch(result.stderr.toString(), new RegExp(marker), 'the parser message is not repeated');
  assert.match(result.stderr.toString(), /left unchanged/);
});
