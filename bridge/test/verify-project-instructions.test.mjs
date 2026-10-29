import assert from 'node:assert/strict';
import test from 'node:test';
import { evaluateVerification, journalStrings, parseJournal } from '../scripts/verify-project-instructions.mjs';

const body = 'Rule one.\nRule two.';
const hash = `sha256:${'a'.repeat(64)}`;
const project = { instructionVersion: 2, instructionHash: hash };
const cleanJournal = `${JSON.stringify({
  seq: 1,
  type: 'session.created',
  payload: { instructionVersion: 2, instructionHash: hash },
})}\n`;

function evaluate(overrides = {}) {
  return evaluateVerification({
    project,
    session: { instructionVersion: 2, instructionHash: hash, phase: 'awaiting_review' },
    result: hash,
    journal: cleanJournal,
    journalTruncated: false,
    resultTruncated: false,
    hash,
    body,
    ...overrides,
  });
}

test('a clean run passes every check', () => {
  const verdict = evaluate();
  assert.equal(verdict.ok, true);
  assert.deepEqual(verdict.checks, {
    identity: true,
    answerIntact: true,
    applied: true,
    journalIntact: true,
    noLeak: true,
    answered: true,
  });
});

test('an answer that appends the body to the hash is not an exact echo', () => {
  // The model echoing the hash and then the instructions must not count as an
  // applied check: only the hash itself (surrounding whitespace allowed) does.
  const verdict = evaluate({ result: `${hash}\n${body}` });
  assert.equal(verdict.checks.applied, false);
  assert.equal(verdict.ok, false);

  const padded = evaluate({ result: `\n  ${hash}  \n` });
  assert.equal(padded.checks.applied, true, 'surrounding whitespace is allowed');
});

test('an errored session with an empty answer and a leaked body is not ok', () => {
  // The body is written into a payload exactly as a regression would: the raw
  // JSONL line carries it escaped, so only a decoded search finds it.
  const leaked = `${cleanJournal}${JSON.stringify({
    seq: 2,
    type: 'session.result',
    payload: { instructions: body },
  })}\n`;
  const verdict = evaluate({
    session: { instructionVersion: 2, instructionHash: hash, phase: 'error' },
    result: '',
    journal: leaked,
  });
  assert.equal(verdict.ok, false);
  assert.equal(verdict.checks.applied, false, 'an empty answer is not an applied instruction');
  assert.equal(verdict.checks.answered, false, 'an errored session is not success');
  assert.equal(verdict.checks.noLeak, false, 'the body in a payload is a leak');
});

test('a body hidden behind JSON escaping is still found', () => {
  const line = JSON.stringify({ payload: { instructions: body } });
  assert.equal(line.includes(body), false, 'the raw line must not match the real body');
  assert.equal(journalStrings(parseJournal(line).events).includes(body), true, 'the decoded search must match it');
});

test('a truncated answer is a failed check even when it trims to the hash', () => {
  // hash + whitespace up to the 64 KiB cut + the body: the visible part trims
  // to the hash, but the cut hides whatever followed it.
  const verdict = evaluate({ result: hash, resultTruncated: true });
  assert.equal(verdict.ok, false);
  assert.equal(verdict.checks.answerIntact, false);
  assert.equal(verdict.checks.applied, false);
});

test('a truncated journal cannot prove the absence of a leak', () => {
  // The artifact is cut at 64 KiB; a body after the cut is invisible, so a
  // truncated journal is a failed check even when the visible part is clean.
  const verdict = evaluate({ journalTruncated: true });
  assert.equal(verdict.ok, false);
  assert.equal(verdict.checks.journalIntact, false);
  assert.equal(verdict.checks.noLeak, false);
});

test('a broken JSONL line is a failed check, not a skipped line', () => {
  const broken = `${cleanJournal}{"seq":2,"payload":{"instructions":`;
  const verdict = evaluate({ journal: broken });
  assert.equal(verdict.ok, false);
  assert.equal(verdict.checks.journalIntact, false);
  assert.equal(verdict.checks.noLeak, false);
  assert.equal(parseJournal(broken).invalid.length, 1);
});

test('a wrong identity or an empty journal is not ok', () => {
  const wrongIdentity = evaluate({ session: { instructionVersion: 1, instructionHash: hash, phase: 'awaiting_review' } });
  assert.equal(wrongIdentity.ok, false);
  assert.equal(wrongIdentity.checks.identity, false);

  const emptyJournal = evaluate({ journal: '' });
  assert.equal(emptyJournal.ok, false);
  assert.equal(emptyJournal.checks.journalIntact, false, 'an empty journal proves nothing');
});
