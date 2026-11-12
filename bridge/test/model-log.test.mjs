import test from 'node:test';
import assert from 'node:assert/strict';
import { attributeReplies, foldModelLog, lastModelChange, markOwnerChange } from '../src/sessions/model-log.mjs';
import { runningModel, snapshot } from '../src/sessions/daemon.mjs';

const fable = { provider: 'claude', model: 'claude-fable-5-2', effort: 'xhigh' };
const opus = { provider: 'claude', model: 'claude-opus-4-8', effort: 'xhigh' };
const at = (minute) => `2026-11-11T07:${String(minute).padStart(2, '0')}:00.000Z`;

test('consecutive observations of one model extend one span', () => {
  let log = foldModelLog(undefined, fable, at(0));
  log = foldModelLog(log, fable, at(5));
  log = foldModelLog(log, opus, at(10));
  log = foldModelLog(log, opus, at(12));
  assert.deepEqual(log, [
    { provider: 'claude', model: 'claude-fable-5-2', from: at(0), to: at(5) },
    { provider: 'claude', model: 'claude-opus-4-8', from: at(10), to: at(12) },
  ]);
  // An observation without a model names nothing and changes nothing.
  assert.deepEqual(foldModelLog(log, { provider: 'claude', model: null }, at(20)), log);
  // An older timestamp never shortens a span.
  assert.deepEqual(foldModelLog(log, opus, at(11)), log);
});

test('the log keeps its newest spans only', () => {
  let log = [];
  for (let index = 0; index < 40; index += 1) {
    log = foldModelLog(log, index % 2 ? fable : opus, at(index));
  }
  assert.equal(log.length, 16);
  assert.equal(log.at(-1).from, at(39));
});

test('the last change says whether the owner asked for it', () => {
  assert.equal(lastModelChange([]), null);
  let log = foldModelLog([], fable, at(0));
  assert.equal(lastModelChange(log), null);
  log = foldModelLog(log, opus, at(10));
  assert.deepEqual(lastModelChange(log), {
    from: { provider: 'claude', model: 'claude-fable-5-2' },
    to: { provider: 'claude', model: 'claude-opus-4-8' },
    seenAt: at(10), byOwner: false,
  });
  assert.equal(lastModelChange(markOwnerChange(log, 'claude-opus-4-8')).byOwner, true);
  // Marking another model leaves the change as the provider's own.
  assert.equal(lastModelChange(markOwnerChange(log, 'claude-sonnet-5-5')).byOwner, false);
});

test('a reply is named only inside a span the Bridge observed', () => {
  const log = [
    { provider: 'claude', model: 'claude-fable-5-2', from: at(10), to: at(20) },
  ];
  const messages = [
    { id: 'old', role: 'assistant', text: 'before the Bridge looked', timestamp: at(5) },
    { id: 'u', role: 'user', text: 'go', timestamp: at(11) },
    { id: 'in', role: 'assistant', text: 'inside', timestamp: at(12) },
    { id: 'late', role: 'assistant', text: 'after the last observation', timestamp: at(25) },
    { id: 'none', role: 'assistant', text: 'no time', timestamp: null },
  ];
  const named = Object.fromEntries(attributeReplies(messages, log).map((m) => [m.id, m.model ?? null]));
  assert.deepEqual(named, {
    old: null, u: null, none: null, late: null,
    in: { provider: 'claude', model: 'claude-fable-5-2' },
  });
  // No log: the messages come back as they were.
  assert.equal(attributeReplies(messages, undefined), messages);
});

test('an unrequested switch takes the name off the turn before it was seen', () => {
  // Turn 1 (07:01) and turn 2 (07:10) ran while Paseo still reported Fable;
  // the provider's fallback happened in turn 2 and showed at turn 3 (07:20).
  const log = [
    { provider: 'claude', model: 'claude-fable-5-2', from: at(0), to: at(19) },
    { provider: 'claude', model: 'claude-opus-4-8', from: at(21), to: at(40) },
  ];
  const messages = [
    { id: 'u1', role: 'user', text: '1', timestamp: at(1) },
    { id: 'a1', role: 'assistant', text: 'turn 1', timestamp: at(2) },
    { id: 'u2', role: 'user', text: '2', timestamp: at(10) },
    { id: 'a2', role: 'assistant', text: 'turn 2', timestamp: at(12) },
    { id: 'u3', role: 'user', text: '3', timestamp: at(20) },
    { id: 'a3', role: 'assistant', text: 'turn 3', timestamp: at(22) },
  ];
  const named = (spans) => Object.fromEntries(attributeReplies(messages, spans)
    .filter((m) => m.role === 'assistant').map((m) => [m.id, m.model?.model ?? null]));
  assert.deepEqual(named(log), { a1: 'claude-fable-5-2', a2: null, a3: 'claude-opus-4-8' });
  // The owner's own switch applies from the next turn: nothing is doubted.
  assert.deepEqual(named(markOwnerChange(log, 'claude-opus-4-8')),
    { a1: 'claude-fable-5-2', a2: 'claude-fable-5-2', a3: 'claude-opus-4-8' });
});

test('a version Paseo maps down to its family keeps the name Claude Code reported', () => {
  const agent = (runtimeInfo, model = 'claude-fable-5-2') => ({ provider: 'claude', model, runtimeInfo });
  // The session this was found in: the mapped value lost "-2" after the first turn.
  assert.equal(runningModel(agent({ model: 'claude-fable-5', extra: { runtimeModel: 'claude-fable-5-2' } })), 'claude-fable-5-2');
  assert.equal(runningModel(agent({ model: 'claude-fable-5', extra: { runtimeModel: 'claude-fable-5-2[1m]' } })), 'claude-fable-5-2');
  // A dated or prefixed spelling of a known model stays on the mapped ID.
  assert.equal(runningModel(agent({ model: 'claude-opus-5-5', extra: { runtimeModel: 'claude-opus-5-5-20261001' } })), 'claude-opus-5-5');
  assert.equal(runningModel(agent({ model: 'claude-opus-5-5', extra: { runtimeModel: 'us.anthropic.claude-opus-5-5-v1:0' } })), 'claude-opus-5-5');
  // A real change of model is not papered over, and nothing is invented.
  assert.equal(runningModel(agent({ model: 'claude-opus-5-5', extra: { runtimeModel: 'claude-opus-5-5' } })), 'claude-opus-5-5');
  assert.equal(runningModel(agent({ model: 'claude-fable-5' })), 'claude-fable-5');
  assert.equal(runningModel(agent(undefined)), 'claude-fable-5-2');
  assert.equal(runningModel({ provider: 'claude' }), null);
  assert.equal(snapshot(agent({ model: 'claude-fable-5', extra: { runtimeModel: 'claude-fable-5-2' } }), 0).modelCheck.observed.model, 'claude-fable-5-2');
});
