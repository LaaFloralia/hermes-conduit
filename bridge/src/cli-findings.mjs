import { join } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';
import { resolveStateDir } from './config.mjs';
import { createFindingStore } from './findings/store.mjs';
import { createFindingService } from './findings/service.mjs';
import { createSessionStore } from './sessions/store.mjs';
import { createRefRegistry, normalizeRefInput } from './refs/registry.mjs';
import { exitCodeFor } from './cli-tasks.mjs';
import { BridgeError } from './errors.mjs';

export const FINDINGS_USAGE = `laa-bridge finding — 気づき（作業は止まりません）
  finding add --request-id <一意のID> --title <題> --found <気づいたこと> --evidence <根拠>
              --plan <対応方法> --effort small|medium|large [--image <絶対パス>]… [--agent <会話ID>] [--name <会話名>] [--json]
  finding list [--status open|delegated|done|all] [--json]
  finding show <ID|F番号> [--json]
  finding delegate <ID|F番号> [--json]
  finding dismiss <ID|F番号> [--json]
  finding pickup <ID|F番号> --plan <計画ID> [--json] （統括用）
  finding done <ID|F番号> --result <結果1行> [--json]
  finding stats [--json]
`;

const ALLOWED = { add: ['request-id', 'title', 'found', 'evidence', 'plan', 'effort', 'image', 'agent', 'name'],
  list: ['status'], show: [], delegate: [], dismiss: [], pickup: ['plan'], done: ['result'], stats: [] };

export async function findingsCommand(argv, flags, io = {}) {
  const write = io.write ?? ((s) => process.stdout.write(s));
  const writeErr = io.writeErr ?? ((s) => process.stderr.write(s));
  const usage = (message) => { throw new BridgeError(428, 'usage_error', message); };
  const local = { local: true };
  try {
    const [sub, given] = argv;
    if (!sub || sub === 'help') { write(FINDINGS_USAGE); return 0; }
    if (!Object.hasOwn(ALLOWED, sub)) usage('不明な finding サブコマンドです。');
    if (argv.length !== (['show', 'delegate', 'dismiss', 'pickup', 'done'].includes(sub) ? 2 : 1)) usage('引数の数が正しくありません。');
    for (const flag of Object.keys(flags)) if (flag !== 'json' && !ALLOWED[sub].includes(flag)) usage(`不明なオプション: --${flag}`);
    const requireFlag = (key) => { if (typeof flags[key] !== 'string' || !flags[key]) usage(`--${key} が必要です。`); return flags[key]; };
    const dir = resolveStateDir();
    const registry = createRefRegistry({ file: join(dir, 'refs.json') });
    const refFor = (kind, key) => { try { return registry.refFor(kind, key); } catch { return null; } };
    const service = createFindingService({ store: createFindingStore({ dir }), refFor,
      sessionStore: createSessionStore({ file: join(dir, 'sessions.json') }) });
    let id = given;
    const asRef = normalizeRefInput(given);
    if (asRef?.kind === 'finding') {
      try { id = registry.resolve(asRef.ref).holder?.key ?? given; } catch { id = given; }
    }
    let result;
    if (sub === 'add') {
      const finding = service.add({ requestId: requireFlag('request-id'), title: requireFlag('title'), found: requireFlag('found'),
        evidence: requireFlag('evidence'), plan: requireFlag('plan'), effort: requireFlag('effort'),
        source: { sessionId: flags.agent ?? process.env.PASEO_AGENT_ID, name: flags.name } }, (flags.image ?? []).map((path) => ({ path })));
      // The CLI never mints refs. Give the running Bridge's local reconciliation
      // one pass to assign a number; the record is already saved if it is offline.
      for (let i = 0; process.env.NODE_TEST_CONTEXT === undefined && !finding.ref && finding.status !== 'dismissed' && i < 12; i++) {
        await wait(125);
        finding.ref = refFor('finding', finding.id);
      }
      result = { finding };
    } else if (sub === 'list') result = service.list({ status: flags.status, ...local });
    else if (sub === 'stats') result = service.stats();
    else {
      const finding = sub === 'show' ? service.get(id, local)
        : sub === 'pickup' ? service.pickup(id, requireFlag('plan'))
          : sub === 'done' ? service.done(id, requireFlag('result')) : service[sub](id, local);
      result = { finding };
    }
    if (flags.json) write(`${JSON.stringify({ ok: true, ...result })}\n`);
    else if (sub === 'add' && result.finding.status !== 'open') {
      const { ref, id: saved, status } = result.finding;
      write(`この依頼の気づきは${status === 'dismissed' ? '見送り' : status === 'done' ? '対応済み' : 'Monetが対応中'}のため更新していません（${ref ? `${ref} · ` : ''}${saved}）。作業は続けてください。\n`);
    } else if (sub === 'add') {
      const { ref, id: saved } = result.finding;
      write(`気づきへ登録しました（${ref ? `${ref} · ` : ''}${saved}）。作業は止めずに続けてください。${ref
        ? `完了報告の提案には${ref}とだけ書きます。` : 'F番号はBridgeの同期待ちです。'}\n`);
    } else if (sub === 'stats') for (const [key, count] of Object.entries(result)) write(`${key}: ${count}\n`);
    else if (sub === 'show') {
      const r = result.finding;
      write(`${r.ref ?? r.id}  ${r.status}  ${r.title}\n気づき: ${r.found}\n根拠: ${r.evidence}\n対応方法: ${r.plan}\n手間: ${r.effort}\n${r.result ? `結果: ${r.result}\n` : ''}`);
    } else for (const r of result.items ?? [result.finding]) write(`${r.ref ?? r.id}  ${r.status}  ${r.title}\n`);
    return 0;
  } catch (error) {
    const body = error instanceof BridgeError ? { code: error.code, message: error.message } : { code: 'internal_error', message: 'unexpected failure' };
    if (flags.json) write(`${JSON.stringify({ ok: false, error: body })}\n`);
    writeErr(`laa-bridge: ${body.code}: ${body.message}\n`);
    return exitCodeFor(error);
  }
}
