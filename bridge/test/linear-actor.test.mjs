import test from 'node:test';
import assert from 'node:assert/strict';
import { createPersonalLinearSource } from '../src/tasks/personal.mjs';

test('app actor attributes creation to the owner; a user agent marks app origin', async () => {
  for (const app of [true, false]) {
    const calls = [];
    const source = createPersonalLinearSource({ agentAccount: true, ownerUserId: 'owner', readToken: async () => 'oauth-fixture',
      fetchImpl: async (_url, options) => {
        const { query, variables } = JSON.parse(options.body); calls.push({ query, variables });
        const data = query.includes('LAAPersonalViewer') ? { viewer: { id: 'agent', app } }
          : query.includes('LAAOwnerProfile') ? { user: { id: 'owner', name: 'Fixture owner', avatarUrl: 'https://example.com/avatar.png' } }
          : query.includes('LAAPersonalIssueCreate') ? { issueCreate: { success: true, issue: { id: 'new', identifier: 'BUS-1' } } }
          : { commentCreate: { success: true, comment: { id: 'comment' } } };
        return new Response(JSON.stringify({ data }), { status: 200 });
      } });
    const session = await source.session(); await source.prepareActor(session);
    await source.createIssue(session, { id: 'new', title: 'Title', description: 'Body' });
    await source.createTaskItem(session, 'comment', { id: 'comment', body: 'Comment' });
    const inputs = calls.filter((v) => v.variables?.input).map((v) => v.variables.input);
    assert.equal(inputs.length, 2);
    if (app) {
      assert.equal(inputs[0].createAsUser, 'Fixture owner'); assert.equal(inputs[1].displayIconUrl, 'https://example.com/avatar.png');
      assert.equal(inputs[0].description, 'Body'); assert.equal(calls.filter((v) => v.query.includes('LAAOwnerProfile')).length, 1);
    } else {
      assert(inputs[0].description.endsWith('— LAAアプリから')); assert(inputs[1].body.endsWith('— LAAアプリから'));
      assert.equal(inputs[0].createAsUser, undefined);
    }
  }
});
