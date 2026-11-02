import assert from 'node:assert/strict';
import test from 'node:test';
import { createPersonalLinearSource } from '../src/tasks/personal.mjs';
import { startBridge } from './helpers.mjs';

const owner = { id: 'fixture-owner', name: 'Owner' };
const privateURL = 'https://uploads.linear.app/fixture/notes.pdf';
const issue = { id: 'issue-1', identifier: 'FIX-1', title: 'Fixture',
  description: `[File](${privateURL}) ![Again](${privateURL})`,
  labels: { nodes: [], pageInfo: { hasNextPage: false } } };
const json = (data) => new Response(JSON.stringify({ data }), { status: 200 });

function fixture() {
  const calls = [];
  const settings = { response: () => new Response('fixture bytes', { status: 200 }), attachmentURL: privateURL };
  const source = createPersonalLinearSource({
    expectedViewerId: owner.id, readToken: async () => 'lin_api_fixture',
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options });
      if (String(url).startsWith('https://uploads.linear.app/')) return settings.response();
      const { query, variables } = JSON.parse(options.body);
      if (query.includes('LAAPersonalViewer')) return json({ viewer: owner });
      if (query.includes('LAAPersonalIssue(')) return json({ issue });
      if (query.includes('LAAPersonalCommentFileSource')) return json({ comment: {
        id: variables.id, issueId: variables.id === 'foreign' ? 'another-issue' : issue.id,
        body: `[File](${privateURL})`,
      } });
      if (query.includes('LAAPersonalAttachmentFileSource')) return json({ attachment: {
        id: variables.id, issue: { id: variables.id === 'foreign' ? 'another-issue' : issue.id },
        url: settings.attachmentURL,
      } });
      throw new Error('unexpected graph operation');
    },
  });
  return { source, calls, settings };
}

test('private files are rechecked against the issue and viewer, with no caller-supplied URLs', async (t) => {
  const { source, calls, settings } = fixture();
  const api = await startBridge({ tasks: { personal: source } }); t.after(() => api.close());
  const token = await api.token(['tasks:read']);
  assert.equal((await api.request('/v1/personal-tasks/FIX-1/files')).status, 401);
  const forbidden = await api.token(['sessions:read']);
  assert.equal((await api.request('/v1/personal-tasks/FIX-1/files', { token: forbidden })).status, 403);
  const list = await api.request('/v1/personal-tasks/FIX-1/files', { token });
  assert.equal(list.status, 200);
  assert.equal(list.body.data.viewerId, owner.id);
  assert.deepEqual(list.body.data.items.map((f) => f.name), ['notes.pdf']);
  assert.doesNotMatch(JSON.stringify(list.body), /uploads\.linear\.app/);
  const id = list.body.data.items[0].id;
  const loaded = await api.request(`/v1/personal-tasks/FIX-1/files/${id}/content`, { token });
  assert.equal(Buffer.from(loaded.body.data.content, 'base64').toString(), 'fixture bytes');
  assert.equal(loaded.body.data.size, 13);
  assert.equal(loaded.headers.get('cache-control'), 'no-store');
  const fileCall = calls.find((c) => c.url === privateURL);
  assert.equal(fileCall.options.headers.authorization, 'lin_api_fixture');
  assert.equal(fileCall.options.redirect, 'manual');
  assert.equal((await api.request(`/v1/personal-tasks/FIX-1/files/${'0'.repeat(64)}/content`, { token })).status, 404);
  assert.equal((await api.request('/v1/personal-tasks/FIX-1/files?comment=foreign', { token })).status, 404);
  assert.equal((await api.request('/v1/personal-tasks/FIX-1/attachments/foreign/content', { token })).status, 404);
  assert.equal((await api.request('/v1/personal-tasks/FIX-1/attachments/own/content', { token })).status, 200);
  settings.attachmentURL = 'https://uploads.linear.app.evil.test/steal';
  assert.equal((await api.request('/v1/personal-tasks/FIX-1/attachments/own/content', { token })).status, 404);
  settings.attachmentURL = 'https://user@uploads.linear.app/file';
  assert.equal((await api.request('/v1/personal-tasks/FIX-1/attachments/own/content', { token })).status, 404);
  assert.equal(calls.filter((c) => c.url.includes('evil.test')).length, 0);
});

test('redirects, oversized files and interrupted streams do not return bytes', async (t) => {
  const { source, settings } = fixture();
  const api = await startBridge({ tasks: { personal: source } }); t.after(() => api.close());
  const token = await api.token(['tasks:read']);
  const path = '/v1/personal-tasks/FIX-1/attachments/own/content';
  settings.response = () => new Response(null, { status: 302, headers: { location: 'https://evil.test/' } });
  assert.equal((await api.request(path, { token })).status, 503);
  settings.response = () => new Response('small', { headers: { 'content-length': String(20 * 1024 * 1024 + 1) } });
  assert.equal((await api.request(path, { token })).status, 413);
  settings.response = () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(20 * 1024 * 1024 + 1)); controller.close(); },
  }));
  assert.equal((await api.request(path, { token })).status, 413);
  settings.response = () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array([1, 2])); controller.error(new Error('sensitive-upstream-fixture')); },
  }));
  const interrupted = await api.request(path, { token });
  assert.equal(interrupted.status, 503);
  assert.doesNotMatch(JSON.stringify(interrupted.body), /sensitive-upstream-fixture/);
});
