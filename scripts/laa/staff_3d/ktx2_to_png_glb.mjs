// Rewrite a KHR_texture_basisu GLB into a PNG-texture GLB (geometry/skin/anim bytes untouched).
// usage: node ktx2_to_png_glb.mjs in.glb out.glb
import fs from 'node:fs'; import path from 'node:path'; import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module'; import os from 'node:os';
const require = createRequire(import.meta.url);
const basisDir = '/Users/laa/dev/hp/public/three/basis';
const src = fs.readFileSync(path.join(basisDir, 'basis_transcoder.js'), 'utf8');
const mod = { exports: {} }; new Function('module', 'exports', 'require', '__dirname', src + '\nmodule.exports = BASIS;')(mod, mod.exports, require, basisDir);
const BASIS = await mod.exports({ wasmBinary: fs.readFileSync(path.join(basisDir, 'basis_transcoder.wasm')) });
BASIS.initializeBasis();
const [inp, out] = process.argv.slice(2);
const b = fs.readFileSync(inp);
const jlen = b.readUInt32LE(12); const json = JSON.parse(b.subarray(20, 20 + jlen).toString());
const binOff = 20 + jlen; const blen = b.readUInt32LE(binOff); let bin = b.subarray(binOff + 8, binOff + 8 + blen);
const extra = []; let cursor = bin.length;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ktx-'));
json.images.forEach((img, i) => {
  if (img.mimeType !== 'image/ktx2') return;
  const bv = json.bufferViews[img.bufferView];
  const data = new Uint8Array(bin.subarray(bv.byteOffset || 0, (bv.byteOffset || 0) + bv.byteLength));
  const k = new BASIS.KTX2File(data); if (!k.isValid()) throw new Error('bad ktx2 ' + i);
  k.startTranscoding();
  const w = k.getWidth(), h = k.getHeight(); const fmt = 13; // cTFRGBA32
  const dst = new Uint8Array(k.getImageTranscodedSizeInBytes(0, 0, 0, fmt));
  if (!k.transcodeImage(dst, 0, 0, 0, fmt, 0, -1, -1)) throw new Error('transcode failed ' + i);
  k.close(); k.delete();
  const raw = path.join(tmp, `i${i}.rgba`), png = path.join(tmp, `i${i}.png`);
  fs.writeFileSync(raw, dst);
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', `${w}x${h}`, '-i', raw, '-frames:v', '1', png]);
  let p = fs.readFileSync(png); const pad = (4 - (cursor % 4)) % 4; extra.push(Buffer.alloc(pad)); cursor += pad;
  json.bufferViews.push({ buffer: 0, byteOffset: cursor, byteLength: p.length }); extra.push(p); cursor += p.length;
  img.bufferView = json.bufferViews.length - 1; img.mimeType = 'image/png';
  console.log('image', i, img.name, w + 'x' + h);
});
for (const t of json.textures) { const e = t.extensions?.KHR_texture_basisu; if (e) { t.source = e.source; delete t.extensions.KHR_texture_basisu; if (!Object.keys(t.extensions).length) delete t.extensions; } }
json.extensionsUsed = json.extensionsUsed.filter(x => x !== 'KHR_texture_basisu');
if (json.extensionsRequired) json.extensionsRequired = json.extensionsRequired.filter(x => x !== 'KHR_texture_basisu');
let newBin = Buffer.concat([bin, ...extra]); const bpad = (4 - newBin.length % 4) % 4; newBin = Buffer.concat([newBin, Buffer.alloc(bpad)]);
json.buffers[0].byteLength = newBin.length;
let js = Buffer.from(JSON.stringify(json)); js = Buffer.concat([js, Buffer.alloc((4 - js.length % 4) % 4, 0x20)]);
const head = Buffer.alloc(12); head.write('glTF', 0); head.writeUInt32LE(2, 4); head.writeUInt32LE(12 + 8 + js.length + 8 + newBin.length, 8);
const c1 = Buffer.alloc(8); c1.writeUInt32LE(js.length, 0); c1.write('JSON', 4);
const c2 = Buffer.alloc(8); c2.writeUInt32LE(newBin.length, 0); c2.write('BIN\0', 4);
fs.writeFileSync(out, Buffer.concat([head, c1, js, c2, newBin])); console.log('wrote', out);
