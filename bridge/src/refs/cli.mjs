// `laa-bridge ref <ref>` and `laa-bridge refs` — read-only views of the
// registry file. They work while the server is down (the personal agent often
// needs a ref during a restart) and never write: opening a missing file yields
// an empty registry in memory, not a new file on disk.

import { join } from 'node:path';
import { resolveStateDir } from '../config.mjs';
import { KINDS, RefInputError, createRefRegistry, normalizeRefInput } from './registry.mjs';
import { briefFor, formatRefLine, formatResultLine } from './present.mjs';

export const REFS_USAGE = `laa-bridge ref  <ref> [--json]       resolve a short number (read-only)
  laa-bridge refs [--kind task|session|project|routine|skill] [--json]
                                            numbers currently held`;

function print(line) {
  process.stdout.write(`${line}\n`);
}

function registryFor(flags) {
  const dir = flags['state-dir'] ?? resolveStateDir();
  return createRefRegistry({ file: join(dir, 'refs.json') });
}

function parseKind(flags) {
  if (flags.kind === undefined) return null;
  if (!KINDS.includes(flags.kind)) {
    process.stderr.write(`laa-bridge: --kind must be one of ${KINDS.join(', ')}\n`);
    return undefined;
  }
  return flags.kind;
}

export function refsCommand(positional, flags) {
  const command = positional[0];
  if (command === 'ref') {
    const input = positional[1];
    if (input === undefined) {
      process.stderr.write('laa-bridge: ref needs a number such as T12\n');
      return 2;
    }
    if (!normalizeRefInput(input)) {
      process.stderr.write('laa-bridge: ref must look like T12 (a letter T/S/P/R/K and a number)\n');
      return 2;
    }
    let registry;
    try {
      registry = registryFor(flags);
      const result = registry.resolve(input);
      if (flags.json) {
        print(JSON.stringify({ ...result, brief: briefFor(result) }));
      } else if (result.status === 'active' && result.holder) {
        print(formatRefLine(result.holder));
      } else if (result.status === 'released') {
        const previous = result.previous[0];
        const at = previous?.releasedAt ?? '';
        const former = previous ? formatRefLine({ ...previous, ref: '' }).trim() : '';
        print(`${result.ref} は解放済み（${at}）。${former ? `最後の持ち主: ${former}` : ''}`);
      } else {
        print(`${result.ref} は未使用です。`);
      }
      return 0;
    } catch (error) {
      if (error instanceof RefInputError) {
        process.stderr.write('laa-bridge: ref must look like T12\n');
        return 2;
      }
      process.stderr.write(`laa-bridge: refs registry is unreadable (${error?.code ?? error?.name ?? 'error'})\n`);
      return 1;
    }
  }

  if (command === 'refs') {
    const kind = parseKind(flags);
    if (kind === undefined) return 2;
    try {
      const registry = registryFor(flags);
      const kinds = kind === null ? KINDS : [kind];
      const items = registry.held(kinds).map((record) => ({
        ref: record.ref,
        kind: record.kind,
        key: record.key,
        title: record.title,
        external: record.external,
      }));
      const observedAt = registry.observedAt(kinds);
      if (flags.json) {
        print(JSON.stringify({ items, observedAt, fetchedAt: new Date().toISOString() }));
        return 0;
      }
      for (const item of items) print(formatRefLine(item));
      print(`observedAt ${Object.entries(observedAt).map(([k, v]) => `${k}=${v ?? '-'}`).join(' ')}`);
      return 0;
    } catch (error) {
      process.stderr.write(`laa-bridge: refs registry is unreadable (${error?.code ?? error?.name ?? 'error'})\n`);
      return 1;
    }
  }

  process.stderr.write('laa-bridge: ref or refs expected\n');
  return 2;
}
