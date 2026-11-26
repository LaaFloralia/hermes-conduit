import { resolvePort, resolveStateDir } from './config.mjs';
import { connectLaneWork } from './lane/adapters.mjs';
import { validateLane } from './lane/guard.mjs';
import { daemonAdapter } from './sessions/daemon.mjs';
import { createDecisionStore } from './decisions/store.mjs';
import { createDecisionService } from './decisions/service.mjs';
import { createSessionStore } from './sessions/store.mjs';
import { exitCodeFor } from './cli-tasks.mjs';
import { BridgeError } from './errors.mjs';
import { createRefRegistry, normalizeRefInput } from './refs/registry.mjs';

export const DECISIONS_USAGE = `laa-bridge decide — 判断ボード
  decide add --title <t> --summary <s> --option <label>[::<detail>] (2..6)
             --impact <t> [--recommended <1-based index>] [--deadline <ISO>]
             [--no-other] [--agent <paseo id>] [--name <title>] --request-id <id> [--json]
  decide status <id|ref> [--json]
  decide withdraw <id|ref> --reason <t> [--json]
  decide answer <id|ref> (--option <1-based>|--note <text>) --by monet --reason <one line> [--json]
  decide list [--monet-log [--since <ISO>]] [--json]
  decide stats [--since <ISO>] [--json]
`;

export async function decisionsCommand(argv, flags, io = {}) {
  const write = io.write ?? ((s) => process.stdout.write(s));
  const writeErr = io.writeErr ?? ((s) => process.stderr.write(s));
  const usage = (message) => { throw new BridgeError(428, 'usage_error', message); };
  let daemon;
  try {
    const [sub, given] = argv;
    if (!sub || sub === 'help') { write(DECISIONS_USAGE); return 0; }
    const allowed = { add: 'title summary option recommended impact deadline no-other agent name request-id json', status: 'json',
      withdraw: 'reason json', answer: 'option note by reason json', list: 'monet-log since json', stats: 'since json' };
    if (!Object.hasOwn(allowed, sub)) usage('unknown decide subcommand');
    if (argv.length !== (['status', 'withdraw', 'answer'].includes(sub) ? 2 : 1)) usage('invalid positional arguments');
    for (const flag of Object.keys(flags)) if (!allowed[sub].split(' ').includes(flag)) usage(`unknown flag --${flag}`);
    const requireFlag = (key) => { if (typeof flags[key] !== 'string' || !flags[key]) usage(`--${key} is required`); return flags[key]; };
    const dir = resolveStateDir();
    // Numbers are read from the server's refs.json, never written here, so the
    // output carries the same J/S numbers the app shows and `status J3` works.
    const registry = createRefRegistry({ file: `${dir}/refs.json` });
    const refs = (kind, key) => { try { return registry.refFor(kind, key); } catch { return null; } };
    if (sub === 'answer') {
      const lane = validateLane(process.env, { stateDir: dir, port: resolvePort() });
      // Never connect to a host daemon from a Node test unless it owns a lane.
      if (lane?.work) daemon = daemonAdapter({ connect: () => connectLaneWork(lane) });
      else if (!lane && process.env.NODE_TEST_CONTEXT === undefined) daemon = daemonAdapter();
    }
    const service = createDecisionService({ store: createDecisionStore({ dir }), sessionStore: createSessionStore({ file: `${dir}/sessions.json` }), daemon, notify: null, refs });
    let id = given;
    const asRef = typeof given === 'string' ? normalizeRefInput(given) : null;
    if (asRef?.kind === 'decision') {
      try { id = registry.resolve(asRef.ref).holder?.key ?? given; } catch { id = given; }
    }
    let result;
    if (sub === 'add') {
      for (const key of ['title', 'summary', 'request-id']) requireFlag(key);
      if (!Array.isArray(flags.option) || flags.option.length < 2 || flags.option.length > 6) usage('repeat --option 2..6 times');
      const recommended = flags.recommended === undefined ? null : Number(flags.recommended);
      if (recommended !== null && (!Number.isInteger(recommended) || recommended < 1 || recommended > flags.option.length)) usage('--recommended is a 1-based option index');
      result = service.add({ title: flags.title, summary: flags.summary,
        options: flags.option.map((value, i) => { const split = value.indexOf('::'); return { label: split < 0 ? value : value.slice(0, split), detail: split < 0 ? null : value.slice(split + 2), recommended: recommended === i + 1 }; }),
        impact: flags.impact, deadline: flags.deadline, allowOther: !flags['no-other'], requestId: flags['request-id'],
        source: { paseoAgentId: flags.agent ?? process.env.PASEO_AGENT_ID ?? null, name: flags.name ?? null } });
      result.decision = service.view(result.decision);
    } else if (sub === 'status') result = { decision: service.get(id) };
    else if (sub === 'withdraw') result = { decision: service.withdraw(id, requireFlag('reason')) };
    else if (sub === 'answer') {
      if (requireFlag('by') !== 'monet') usage('--by must be monet');
      if ((flags.option === undefined) === (flags.note === undefined)) usage('choose one of --option or --note');
      if (flags.option !== undefined && (flags.option.length !== 1 || !/^[1-6]$/.test(flags.option[0]))) usage('--option is one 1-based index');
      const body = flags.option ? { optionIndex: Number(flags.option[0]) - 1 } : { note: requireFlag('note') };
      result = await service.answerAsMonet({ id, body, reason: requireFlag('reason') });
    } else if (sub === 'stats') result = service.stats(flags.since);
    else if (flags['monet-log']) result = { items: service.monetLog(flags.since) };
    else {
      if (flags.since !== undefined) usage('list --since requires --monet-log');
      result = { items: (await service.list({ local: true })).items };
    }
    if (flags.json) write(`${JSON.stringify({ ok: true, ...result })}\n`);
    else if (sub === 'add') write(`判断ボードへ登録しました（${result.decision.ref ? `${result.decision.ref} · ` : ''}${result.decision.id}）。${result.decision.category === 'owner' ? '社長' : 'Monet'}の回答はこの会話に届きます。ここで手番を終えてください。\n`);
    else if (sub === 'stats') for (const [key, count] of Object.entries(result)) write(`${key}: ${count}\n`);
    else if (flags['monet-log']) for (const r of result.items) write(`${r.time}  ${r.subject}  ${r.chosenOption}  ${r.reason}\n`);
    else if (result.decision) write(`${result.decision.id}  ${result.decision.status}  ${result.decision.title}\n回答: ${result.decision.answer?.label ?? '未回答'}\n配達: ${result.decision.delivery?.state ?? '未回答'}${result.decision.delivery?.waiting ? '（会話が空き次第、自動で届けます）' : ''}\n`);
    else for (const r of result.items) write(`${r.ref ?? r.id ?? r.sessionId}  ${r.status}  ${r.category}  ${r.title}\n`);
    return 0;
  } catch (e) {
    const body = e instanceof BridgeError ? { code: e.code, message: e.message } : { code: 'internal_error', message: 'unexpected failure' };
    if (flags.json) write(`${JSON.stringify({ ok: false, error: body })}\n`);
    writeErr(`laa-bridge: ${body.code}: ${body.message}\n`);
    return exitCodeFor(e);
  } finally {
    daemon?.close();
  }
}
