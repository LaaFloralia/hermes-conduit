import assert from 'node:assert/strict';
import test from 'node:test';
import { evaluateVerification, journalStrings } from '../scripts/verify-project-instructions.mjs';

const body = 'Rule one.\nRule two.';
const hash = `sha256:${'a'.repeat(64)}`;
const project = { instructionVersion: 2, instructionHash: hash };
const cleanJournal = `${JSON.stringify({
  seq: 1,
  type: 'session.created',
  payload: { instructionVersion: 2, instructionHash: hash },
})}\n`;

test('a clean run passes every check', () => {
  const verdict = evaluateVerification({
    project,
    session: { instructionVersion: 2, instructionHash: hash, phase: 'awaiting_review' },
    result: hash,
    journal: cleanJournal,
    hash,
    body,
  });
  assert.equal(verdict.ok, true);
  assert.deepEqual(verdict.checks, { identity: true, applied: true, noLeak: true, answered: true });
});

test('an errored session with an empty answer and a leaked body is not ok', () => {
  // The body is written into a payload exactly as a regression would: the raw
  // JSONL line carries it escaped, so only a decoded search finds it.
  const leaked = `${cleanJournal}${JSON.stringify({
    seq: 2,
    type: 'session.result',
    payload: { instructions: body },
  })}\n`;
  const verdict = evaluateVerification({
    project,
    session: { instructionVersion: 2, instructionHash: hash, phase: 'error' },
    result: '',
    journal: leaked,
    hash,
    body,
  });
  assert.equal(verdict.ok, false);
  assert.equal(verdict.checks.applied, false, 'an empty answer is not an applied instruction');
  assert.equal(verdict.checks.answered, false, 'an errored session is not success');
  assert.equal(verdict.checks.noLeak, false, 'the body in a payload is a leak');
});

test('a body hidden behind JSON escaping is still found', () => {
  const line = JSON.stringify({ payload: { instructions: body } });
  assert.equal(line.includes(body), false, 'the raw line must not match the real body');
  assert.equal(journalStrings(line).includes(body), true, 'the decoded search must match it');
});

test('a wrong identity or an empty journal is not ok', () => {
  const wrongIdentity = evaluateVerification({
    project,
    session: { instructionVersion: 1, instructionHash: hash, phase: 'awaiting_review' },
    result: hash,
    journal: cleanJournal,
    hash,
    body,
  });
  assert.equal(wrongIdentity.ok, false);
  assert.equal(wrongIdentity.checks.identity, false);

  const emptyJournal = evaluateVerification({
    project,
    session: { instructionVersion: 2, instructionHash: hash, phase: 'awaiting_review' },
    result: hash,
    journal: '',
    hash,
    body,
  });
  assert.equal(emptyJournal.ok, false);
  assert.equal(emptyJournal.checks.noLeak, false, 'an empty journal proves nothing');
});
