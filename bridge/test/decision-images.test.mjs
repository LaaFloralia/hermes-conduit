import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync,
  symlinkSync, truncateSync, utimesSync, writeFileSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createDecisionService } from '../src/decisions/service.mjs';
import { createDecisionStore } from '../src/decisions/store.mjs';
import { startBridge } from './helpers.mjs';

const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAgAAAAECAIAAAA8r+mnAAAAFklEQVR4nGP4z8DAAMb/wTQcMVBPAgBOah/h5EgP7QAAAABJRU5ErkJggg==', 'base64');
const webp = Buffer.from('UklGRlYAAABXRUJQVlA4IEoAAACwAgCdASoIAAQAAgA0JagCdLoAyQDJAP0ABbtZdRAA/u+j6T//YIl1/ZbAeN37Gn077xu+iX/66D/vIqV/+QH/9Dr/vIqV/48gAA==', 'base64');
const cli = fileURLToPath(new URL('../bin/laa-bridge', import.meta.url));
const mac = { skip: process.platform !== 'darwin' && 'conversion uses macOS sips' };
const imgId = 'img_000000000001';
const DAY = 86400_000, HOUR = DAY / 24;
const mode = (path) => statSync(path).mode & 0o777;
const add = { title: '合成の判断', summary: '試験用', impact: '【任せられる】', options: [{ label: '案A' }, { label: '案B' }] };

function cliFixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'laa-lane-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const subdir of ['home', 'tmp', 'brain']) mkdirSync(join(root, subdir), { mode: 0o700 });
  const dir = join(root, 'state');
  const env = { HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'), PATH: `${dirname(process.execPath)}:/usr/bin:/bin`,
    LAA_LANE_ID: 'decision-images-unit', LAA_LANE_ROOT: root, LAA_BRIDGE_STATE_DIR: dir, LAA_BRIDGE_PORT: '0', LAA_BRIDGE_BRAIN_ROOT: join(root, 'brain') };
  function run(args, options = ['案A', '案B'], requestId = 'media-test') {
    const result = spawnSync(cli, ['decide', 'add', '--title', add.title, '--summary', add.summary, '--impact', add.impact,
      '--request-id', requestId, '--json', ...options.flatMap((o) => ['--option', o]), ...args], { env, encoding: 'utf8', timeout: 90_000 });
    assert.ifError(result.error);
    assert.equal(result.signal, null);
    assert.ok(result.stdout, result.stderr);
    return { status: result.status, json: JSON.parse(result.stdout), stderr: result.stderr };
  }
  return { root, dir, files: join(dir, 'decision-images'), run };
}

function sips(...args) {
  const r = spawnSync('/usr/bin/sips', args, { encoding: 'utf8', timeout: 30_000 });
  assert.ifError(r.error);
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
}

// A valid PNG tEXt chunk with a synthetic comment (length, tag, value, CRC).
const pngComment = Buffer.from('0000002074455874436f6d6d656e740073796e7468657469632070726976617465206d61726b6572fd3de479', 'hex');

function jpegExif(bytes) {
  // Synthetic EXIF with orientation=6 and GPS IFD containing latitude 1°2'3".
  const tiff = Buffer.from('49492a0008000000020012010300010000000600000025880400010000002600000000000000010002000500030000003800000000000000010000000100000002000000010000000300000001000000', 'hex');
  const app = Buffer.concat([Buffer.from([0xff, 0xe1, 0, tiff.length + 8]), Buffer.from('Exif\0\0'), tiff]);
  return Buffer.concat([bytes.subarray(0, 2), app, bytes.subarray(2)]);
}

test('decision CLI rejects relative, missing, directory, wrong-magic, oversized and >6 images before writing', (t) => {
  const f = cliFixture(t);
  const good = join(f.root, 'input.txt'), bad = join(f.root, 'wrong.png'), big = join(f.root, 'oversize.png');
  writeFileSync(good, png);
  writeFileSync(bad, 'wrong magic');
  writeFileSync(big, png);
  truncateSync(big, 40 * 1024 * 1024 + 1);
  const invalid = (outcome) => {
    assert.notEqual(outcome.status, 0);
    assert.equal(outcome.json.error.code, 'decision_image_invalid', outcome.stderr);
    assert.equal(existsSync(f.dir), false);
  };
  const outside = mkdtempSync(join(tmpdir(), 'decision-image-outside-'));
  t.after(() => rmSync(outside, { recursive: true, force: true }));
  const external = join(outside, 'valid.png'), link = join(f.root, 'outside.png');
  writeFileSync(external, png);
  symlinkSync(external, link);
  for (const wrong of ['input.txt', join(f.root, 'missing.png'), f.root, bad, big, external, link]) {
    invalid(f.run(['--image', good, '--image', wrong]));
  }
  invalid(f.run(Array.from({ length: 7 }, () => ['--image', good]).flat()));
  invalid(f.run([], [`案A::image=${good}::image=${good}`, '案B']));
  invalid(f.run([], ['案A::image=', '案B']));
});

test('decision CLI copies ordered images, caps both sizes, strips metadata and replays without new files', mac, (t) => {
  const f = cliFixture(t);
  const pngSource = join(f.root, 'colored.png'), wide = join(f.root, 'large screenshot.data'), jpgSource = join(f.root, 'small.jpg');
  const jpg = join(f.root, 'exif.txt'), heic = join(f.root, 'phone.heic'), web = join(f.root, 'web.png');
  writeFileSync(pngSource, png);
  sips('-z', '200', '4000', pngSource, '--out', wide);
  const widePng = readFileSync(wide);
  writeFileSync(wide, Buffer.concat([widePng.subarray(0, 33), pngComment, widePng.subarray(33)]));
  sips('-s', 'format', 'jpeg', pngSource, '--out', jpgSource);
  writeFileSync(jpg, jpegExif(readFileSync(jpgSource)));
  sips('-s', 'format', 'heic', pngSource, '--out', heic);
  writeFileSync(web, webp);
  const args = ['--recommended', '2', '--image', wide, '--image', web];
  const options = [`案A::詳細A::image=${jpg}`, `案B::image=${heic}`, '案C'];
  const added = f.run(args, options);
  assert.equal(added.status, 0, added.stderr);
  const { decision: d } = added.json;
  assert.equal(added.json.replayed, false);
  assert.deepEqual(d.options.map(({ label, detail }) => [label, detail]), [['案B', null], ['案A', '詳細A'], ['案C', null]]);
  assert.deepEqual(d.images.map(({ id, ...fields }) => {
    assert.match(id, /^img_[0-9a-f]{12}$/);
    return fields;
  }), [{ width: 3000, height: 150 }, { width: 8, height: 4 }, { width: 4, height: 8, option: 1 }, { width: 8, height: 4, option: 0 }]);

  const stored = join(f.files, d.id);
  for (const dir of [f.files, join(f.files, '.staging'), stored]) assert.equal(mode(dir), 0o700);
  const filenames = readdirSync(stored).sort();
  assert.equal(filenames.length, 8);
  for (const name of filenames) assert.equal(mode(join(stored, name)), 0o600);
  assert.equal(mode(join(f.dir, 'decisions.json')), 0o600);
  assert(!readFileSync(join(f.dir, 'decisions.json'), 'utf8').includes(f.root));
  for (const [i, image] of d.images.entries()) {
    const ext = i === 0 ? 'png' : 'jpg';
    for (const size of ['full', 'thumb']) {
      const file = join(stored, `${image.id}.${size}.${ext}`);
      const bytes = readFileSync(file);
      assert(!bytes.includes('synthetic private marker'));
      assert(!bytes.includes(Buffer.from('Exif\0\0')));
      const info = sips('-g', 'pixelWidth', '-g', 'pixelHeight', file);
      const expected = i === 0 && size === 'thumb' ? [720, 36] : [image.width, image.height];
      assert.match(info, new RegExp(`  pixelWidth: ${expected[0]}\\n  pixelHeight: ${expected[1]}\\n`));
    }
  }
  const replay = f.run(args, options);
  assert.equal(replay.status, 0, replay.stderr);
  assert.equal(replay.json.replayed, true);
  assert.deepEqual(replay.json.decision, d);
  assert.deepEqual(readdirSync(f.files).sort(), ['.staging', d.id]);
  assert.deepEqual(readdirSync(join(f.files, '.staging')), []);
  assert.deepEqual(readdirSync(stored).sort(), filenames);
  for (const path of [wide, web, jpg, heic]) rmSync(path);
  const store = createDecisionStore({ dir: f.dir });
  assert.equal(store.image(d.id, d.images[0].id, 'thumb').width, 720);
  assert.equal(store.image(d.id, d.images[2].id, 'full').contentType, 'image/jpeg');

  const legacy = f.run([], ['案A', '案B'], 'legacy');
  assert.equal(legacy.status, 0, legacy.stderr);
  assert(!Object.hasOwn(store.get(legacy.json.decision.id), 'images'));
  store.reserve(legacy.json.decision.id, 'test-device', { requestId: 'answer-no-image', optionIndex: 0 });
  assert.equal(store.get(legacy.json.decision.id).status, 'answered');
});

function rawGet(base, path, token) {
  return new Promise((resolve, reject) => {
    const { hostname, port } = new URL(base);
    const req = httpRequest({ hostname, port, path, headers: { authorization: `Bearer ${token}` } }, (resp) => {
      resp.resume();
      resp.on('end', () => resolve(resp.statusCode));
      resp.on('error', reject);
    });
    req.setTimeout(5000, () => req.destroy(new Error('GET timed out')));
    req.on('error', reject).end();
  });
}

test('decision HTTP images require sessions:read, revalidate ETags and reject unknown or traversing paths', async (t) => {
  const h = await startBridge();
  t.after(() => h.close());
  const store = createDecisionStore({ dir: h.stateDir });
  const d = store.add({ ...add, requestId: 'http' }).decision;
  const r = store.add({ ...add, requestId: 'old-no-images' }).decision;
  // Seed the documented disk layout so the HTTP/retention checks also run in Linux CI.
  const doc = JSON.parse(readFileSync(store.file));
  doc.records.find(({ id }) => id === d.id).images = [{ id: imgId, width: 8, height: 4 }];
  writeFileSync(store.file, JSON.stringify(doc));
  const dir = join(h.stateDir, 'decision-images', d.id);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const size of ['full', 'thumb']) writeFileSync(join(dir, `${imgId}.${size}.png`), png, { mode: 0o600 });
  const url = `/v1/decisions/${d.id}/images/${imgId}`;
  const token = await h.token(['sessions:read']);
  const other = await h.token(['brain:read']);
  assert.equal((await h.request(url)).status, 401);
  assert.equal((await h.request(url, { token: other })).status, 403);
  assert.deepEqual((await h.request(`/v1/decisions/${d.id}`, { token })).body.data.images, [{ id: imgId, width: 8, height: 4 }]);
  assert(!Object.hasOwn((await h.request(`/v1/decisions/${r.id}`, { token })).body.data, 'images'));
  for (const path of [url, `${url}?size=thumb`]) {
    const response = await h.request(path, { token });
    assert.equal(response.status, 200);
    const { contentType, width, height, etag, data } = response.body.data;
    assert.deepEqual({ contentType, width, height }, { contentType: 'image/png', width: 8, height: 4 });
    assert.deepEqual(Buffer.from(data, 'base64'), png);
    assert.equal(etag, response.headers.get('etag'));
    const cached = await h.request(path, { token, headers: { 'if-none-match': etag } });
    assert.equal(cached.status, 304);
    assert.equal(cached.headers.get('etag'), etag);
    assert.equal(cached.body, null);
    assert.equal((await h.request(path, { token, headers: { 'if-none-match': '"different"' } })).status, 200);
  }
  for (const path of [`/v1/decisions/dec_0000000000000000/images/${imgId}`, `/v1/decisions/${r.id}/images/${imgId}`, `${url.slice(0, -1)}2`]) {
    const outcome = await h.request(path, { token });
    assert.equal(outcome.status, 404);
    assert.equal(outcome.body.error.code, 'decision_image_not_found');
  }
  for (const path of [url.replace('/images/', '/%2e%2e/' + d.id + '/images/'), `${url}/../${imgId}`, `${url}%2f..%2fdecisions.json`, url.replace(d.id, '%2e%2e%2fdecisions.json')]) {
    assert.equal(await rawGet(h.base, path, token), 404);
  }
  rmSync(join(dir, `${imgId}.full.png`));
  assert.equal((await h.request(url, { token })).body.error.code, 'decision_image_not_found');
  symlinkSync(join(dir, `${imgId}.thumb.png`), join(dir, `${imgId}.full.png`));
  assert.equal((await h.request(url, { token })).body.error.code, 'decision_image_not_found');
});

test('decision sync prunes images at seven days and old orphan/staging dirs, retaining metadata and 410', async (t) => {
  let clock = Date.now();
  const now = () => clock;
  const h = await startBridge({ now });
  t.after(() => h.close());
  const store = createDecisionStore({ dir: h.stateDir, now });
  const service = createDecisionService({ store, now, notify: null });
  const open = store.add({ ...add, requestId: 'open' }).decision;
  const answered = store.add({ ...add, requestId: 'answered' }).decision;
  const withdrawn = store.add({ ...add, requestId: 'withdrawn' }).decision;
  clock += DAY;
  store.reserve(answered.id, 'test-device', { requestId: 'answer', optionIndex: 0 });
  store.withdraw(withdrawn.id, 'withdraw');
  const root = join(h.stateDir, 'decision-images');
  const doc = JSON.parse(readFileSync(store.file));
  for (const r of doc.records) {
    r.images = [{ id: imgId, width: 8, height: 4 }];
    const dir = join(root, r.id);
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeFileSync(join(dir, `${imgId}.full.png`), png);
  }
  writeFileSync(store.file, JSON.stringify(doc));
  clock += 7 * DAY - 1;
  const scratch = [join(root, 'dec_0000000000000001'), join(root, '.staging', 'abandoned-upload'),
    join(root, 'dec_0000000000000002'), join(root, '.staging', 'active-upload')];
  scratch.forEach((dir, index) => {
    mkdirSync(dir, { recursive: true });
    const mtime = new Date(clock - HOUR + (index < 2 ? -1000 : 1000));
    utimesSync(dir, mtime, mtime);
  });
  await service.sync();
  assert.deepEqual(scratch.map(existsSync), [false, false, true, true]);
  assert(existsSync(join(root, answered.id)));
  assert(existsSync(join(root, withdrawn.id)));
  const token = await h.token(['sessions:read']);
  const get = (r, img = imgId) => h.request(`/v1/decisions/${r.id}/images/${img}`, { token });
  assert.equal((await get(answered)).status, 200);
  clock++;
  await service.sync();
  for (const r of [answered, withdrawn]) {
    assert(!existsSync(join(root, r.id)));
    assert.deepEqual(store.get(r.id).images, [{ id: imgId, width: 8, height: 4 }]);
    const result = await get(r);
    assert.equal(result.status, 410);
    assert.equal(result.body.error.code, 'decision_image_expired');
    assert.equal((await get(r, 'img_000000000002')).status, 404);
  }
  assert.equal((await get(open)).status, 200);
});

test('D-47: decide images writes an item\'s images for Monet\'s design choice without touching the board', mac, (t) => {
  const f = cliFixture(t);
  const a = join(f.root, 'a.png'), b = join(f.root, 'b.png'), general = join(f.root, 'g.png');
  for (const p of [a, b, general]) writeFileSync(p, png);
  const added = f.run(['--image', general], [`案A::image=${a}`, `案B::image=${b}`]);
  assert.equal(added.status, 0, added.stderr);
  const id = added.json.decision.id;
  const before = readFileSync(join(f.dir, 'decisions.json'));
  const out = join(f.root, 'out');
  const env = { HOME: join(f.root, 'home'), TMPDIR: join(f.root, 'tmp'), PATH: `${dirname(process.execPath)}:/usr/bin:/bin`,
    LAA_LANE_ID: 'decision-images-unit', LAA_LANE_ROOT: f.root, LAA_BRIDGE_STATE_DIR: f.dir, LAA_BRIDGE_PORT: '0', LAA_BRIDGE_BRAIN_ROOT: join(f.root, 'brain') };
  const run = (args) => spawnSync(cli, ['decide', 'images', ...args], { env, encoding: 'utf8', timeout: 90_000 });
  const r = run([id, '--out', out, '--json']);
  assert.equal(r.status, 0, r.stderr);
  const { images } = JSON.parse(r.stdout);
  assert.deepEqual(images.map((i) => i.option).sort(), [1, 2, null].sort());
  for (const i of images) { assert(i.path.startsWith(out)); assert.equal(mode(i.path), 0o600); assert.ok(statSync(i.path).size > 0); }
  assert.deepEqual(readFileSync(join(f.dir, 'decisions.json')), before);
  assert.notEqual(run([id, '--out', 'relative']).status, 0);
});
