import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createGoogleDrive } from '../src/drive/google.mjs';
import { startBridge } from './helpers.mjs';

const markdown = '# Rules\n\n| Where | What |\n| --- | --- |\n| Studio | Source |';
const document = { id: 'doc_rules_1', name: 'Drive運用ルール', version: '21',
  mimeType: 'application/vnd.google-apps.document', capabilities: { canDownload: true } };
const studio = { id: 'studio_folder_1', name: 'Studio', mimeType: 'application/vnd.google-apps.folder' };
const studioFile = { ...document, id: 'studio_rules_1', name: 'Custom.md', mimeType: 'text/markdown' };

function adapter({ files = [document], nextPageToken, after = files, status = {}, bytes = markdown, studioRules = [studioFile] } = {}) {
  const reads = [];
  let metadataReads = 0;
  const connection = {
    async request(input) {
      const url = new URL(input);
      assert.equal(url.origin, 'https://www.googleapis.com');
      reads.push(url);
      if (url.pathname === '/drive/v3/files') {
        const q = url.searchParams.get('q');
        if (q.includes("name = 'Studio'")) return Response.json({ files: [studio] });
        if (q.includes(`'${studio.id}' in parents`)) return Response.json({ files: studioRules });
        assert.match(q, /^trashed = false and 'root' in parents and \(name = 'Drive運用ルール' or name = 'Drive運用ルール.md'\)$/);
        return Response.json({ files: metadataReads++ === 0 ? files : after, nextPageToken });
      }
      return new Response(bytes, { headers: { 'content-type': status.mimeType ?? 'text/markdown; charset=utf-8' } });
    },
    json(response) { return response.json(); },
  };
  return { drive: createGoogleDrive({ connection, studioRuleName: 'Custom.md' }), reads };
}

test('operating rules resolve exact canonical parents and read Google Markdown or one literal Markdown file', async () => {
  const { drive, reads } = adapter();
  assert.deepEqual(await drive.operatingRules('drive'), { markdown });
  assert.equal(reads[1].pathname, `/drive/v3/files/${document.id}/export`);
  assert.equal(reads[1].searchParams.get('mimeType'), 'text/markdown');
  assert.deepEqual(await drive.operatingRules('studio'), { markdown });
  assert.match(reads[4].searchParams.get('q'), /name = 'Custom\.md'/);
  assert.equal(reads[5].pathname, `/drive/v3/files/${studioFile.id}`);
  assert.equal(reads[5].searchParams.get('alt'), 'media');
  assert.equal(await adapter({ studioRules: [] }).drive.operatingRules('studio'), null);
});

test('rules fail closed on ambiguous, unpermitted, stale, unsupported or invalid content', async () => {
  for (const [options, code] of [
    [{ files: [document, document] }, 'rules_ambiguous'],
    [{ nextPageToken: 'unread' }, 'rules_ambiguous'],
    [{ files: [{ ...document, capabilities: {} }] }, 'download_forbidden'],
    [{ after: [{ ...document, version: '22' }] }, 'version_changed'],
    [{ status: { mimeType: 'text/html' } }, 'rules_unsupported'],
    [{ bytes: new Uint8Array([0xff, 0xfe]) }, 'rules_invalid'],
    [{ bytes: 'x'.repeat(256 * 1024 + 1) }, 'drive_export_too_large'],
  ]) await assert.rejects(adapter(options).drive.operatingRules('drive'), { code });
});

test('rules route requires media:read and exposes only the two named sources', async () => {
  const bridge = await startBridge({ drive: adapter({ studioRules: [] }).drive });
  try {
    const token = async scopes => {
      const { code } = await bridge.pair({ scopes });
      const result = await bridge.enroll(code);
      assert.equal(result.status, 201);
      return result.body.data.token;
    };
    const read = await token(['media:read']);
    const other = await token(['brain:read']);
    const route = '/v1/drive/rules';
    assert.equal((await bridge.request(`${route}/drive`)).status, 401);
    assert.equal((await bridge.request(`${route}/drive`, { token: other })).status, 403);
    assert.deepEqual((await bridge.request(`${route}/drive`, { token: read })).body.data, { markdown });
    const missing = await bridge.request(`${route}/studio`, { token: read });
    assert.equal(missing.status, 404);
    assert.equal(missing.body.error.code, 'rules_missing');
    assert.equal((await bridge.request(`${route}/arbitrary`, { token: read })).status, 404);
  } finally { await bridge.close(); }
});
