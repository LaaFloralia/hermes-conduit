#!/usr/bin/env node
// Stand-in for the on-device voice worker in Bridge tests.
//
// It speaks the real stdio protocol (one JSON object per line) but never loads
// a model, so the suite stays fast and needs no MLX. Failure behaviour is
// selected per test:
//
//   STUB_DELAY_MS     wait before answering (for parallel/busy tests)
//   STUB_ONCE=exit|hang|garbage
//                     misbehave on the first request only, then behave
//   STUB_ONCE_FILE    marker used to make "first" survive a restart
//
// A transcribe request is answered with a short synthetic sentence unless every
// PCM byte is zero, which stands for silence and answers with empty text.

import { existsSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const delayMs = Number(process.env.STUB_DELAY_MS ?? 0);
const onceMode = process.env.STUB_ONCE ?? '';
const marker = process.env.STUB_ONCE_FILE ?? '';
const stderrText = process.env.STUB_STDERR ?? '';
const slowText = process.env.STUB_SLOW_TEXT ?? '';
const slowMs = Number(process.env.STUB_SLOW_MS ?? 260);
const staleMs = Number(process.env.STUB_STALE_MS ?? 120);
const termFile = process.env.STUB_TERM_FILE ?? '';
const hangAfter = Number(process.env.STUB_HANG_AFTER ?? 0);
let served = 0;

// A registered SIGTERM handler keeps Node alive, which is how `ignore_term`
// and the cancellation test observe the Bridge's TERM→KILL escalation.
if (termFile !== '') process.on('SIGTERM', () => writeFileSync(termFile, '1'));

function firstRequest() {
  if (marker === '') return false;
  if (existsSync(marker)) return false;
  writeFileSync(marker, '1');
  return true;
}

const lines = createInterface({ input: process.stdin });
lines.on('line', (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    process.stdout.write('this is not json\n');
    return;
  }
  if (stderrText !== '') process.stderr.write(`leaking ${stderrText}\n`);
  served += 1;
  if (hangAfter !== 0 && served > hangAfter) return;
  const first = firstRequest();
  if (first && onceMode === 'exit') {
    process.exit(7);
  }
  if (first && onceMode === 'exit3') {
    process.exit(3);
  }
  if (first && onceMode === 'exit4') {
    process.exit(4);
  }
  if (first && onceMode === 'hang') {
    return;
  }
  if (first && onceMode === 'unavailable') {
    process.stdout.write(`${JSON.stringify({ id: message.id, ok: false, error: 'unavailable' })}\n`);
    return;
  }
  if (first && onceMode === 'huge_utf8') {
    process.stdout.write(`${'あ'.repeat(100000)}\n`);
    return;
  }
  if (first && onceMode === 'huge_utf8_split') {
    const text = 'あ'.repeat(100000);
    let offset = 0;
    const timer = setInterval(() => {
      process.stdout.write(text.slice(offset, offset + 20000));
      offset += 20000;
      if (offset >= text.length) {
        clearInterval(timer);
        process.stdout.write('\n');
      }
    }, 20);
    return;
  }
  if (first && onceMode === 'internal') {
    process.stdout.write(`${JSON.stringify({ id: message.id, ok: false, error: 'internal' })}\n`);
    return;
  }
  if (first && onceMode === 'empty') {
    process.stdout.write(`${JSON.stringify({ id: message.id, ok: false, error: 'empty' })}\n`);
    return;
  }
  if (first && onceMode === 'nothing') {
    process.stdout.write(`${JSON.stringify({ id: message.id, ok: true, text: '', nothing: true })}\n`);
    return;
  }
  if (first && onceMode === 'nothing_bad') {
    process.stdout.write(`${JSON.stringify({ id: message.id, ok: true, text: 'x', nothing: true })}\n`);
    return;
  }
  if (first && onceMode === 'huge') {
    process.stdout.write(`${'x'.repeat(300 * 1024)}\n`);
    return;
  }
  if (first && onceMode === 'huge_no_newline') {
    process.stdout.write('x'.repeat(300 * 1024));
    return;
  }
  if (first && onceMode === 'ignore_term') {
    return;
  }
  if (first && onceMode === 'stale') {
    // Never answer: the Bridge times out and kills this child. The handler
    // flushes a late reply with the old id after the replacement is running.
    const staleId = message.id;
    process.on('SIGTERM', () => {
      setTimeout(() => {
        process.stdout.write(`${JSON.stringify({ id: staleId, ok: true, text: 'stale reply' })}\n`);
        process.exit(0);
      }, staleMs);
    });
    return;
  }
  if (first && onceMode === 'garbage') {
    process.stdout.write('{"id":"someone-else","ok":true,"text":"x"}\n');
    return;
  }

  // A missing `kind` is a polish request, as in the text-only worker.
  if (message.kind === 'transcribe') {
    const pcm = Buffer.from(typeof message.pcm16 === 'string' ? message.pcm16 : '', 'base64');
    const silence = pcm.length === 0 || pcm.every((byte) => byte === 0);
    const text = silence ? '' : `transcribed ${pcm.length} bytes at ${message.sampleRate}`;
    setTimeout(() => {
      process.stdout.write(`${JSON.stringify({ id: message.id, ok: true, text })}\n`);
    }, delayMs);
    return;
  }

  const wait = slowText !== '' && message.text === slowText ? slowMs : delayMs;
  setTimeout(() => {
    process.stdout.write(`${JSON.stringify({
      id: message.id,
      ok: true,
      text: `${message.kind === 'summarize' ? 'summary' : 'polished'}: ${message.text}`,
    })}\n`);
  }, wait);
});
