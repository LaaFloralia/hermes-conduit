import { resolveStateDir } from './config.mjs';
import { createDecisionStore } from './decisions/store.mjs';
import { createDecisionService } from './decisions/service.mjs';
import { createSessionStore } from './sessions/store.mjs';
import { exitCodeFor } from './cli-tasks.mjs';
import { BridgeError } from './errors.mjs';

export const DECISIONS_USAGE = `laa-bridge decide — 判断ボード
  decide add --title <t> --summary <s> --option <label>[::<detail>] (2..6)
             [--recommended <1-based index>] [--impact <t>] [--deadline <ISO>]
             [--no-other] [--agent <paseo id>] [--name <title>] --request-id <id> [--json]
  decide status <id|ref> [--json]
  decide withdraw <id|ref> --reason <t> [--json]
  decide list [--json]
`;

export async function decisionsCommand(argv, flags, io = {}) {
  const write = io.write ?? ((s) => process.stdout.write(s));
  const writeErr = io.writeErr ?? ((s) => process.stderr.write(s));
  const usage = (message) => { throw new BridgeError(428, 'usage_error', message); };
  try {
    const [sub, id] = argv;
    if (!sub || sub === 'help') { write(DECISIONS_USAGE); return 0; }
    const allowed = { add: 'title summary option recommended impact deadline no-other agent name request-id json', status: 'json', withdraw: 'reason json', list: 'json' };
    if (!allowed[sub]) usage('unknown decide subcommand');
    if (argv.length !== (['status', 'withdraw'].includes(sub) ? 2 : 1)) usage('invalid positional arguments');
    for (const flag of Object.keys(flags)) if (!allowed[sub].split(' ').includes(flag)) usage(`unknown flag --${flag}`);
    const requireFlag = (key) => { if (typeof flags[key] !== 'string' || !flags[key]) usage(`--${key} is required`); return flags[key]; };
    const dir = resolveStateDir();
    const service = createDecisionService({ store: createDecisionStore({ dir }), sessionStore: createSessionStore({ file: `${dir}/sessions.json` }), notify: null });
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
    else result = { items: (await service.list()).items };
    if (flags.json) write(`${JSON.stringify({ ok: true, ...result })}\n`);
    else if (sub === 'add') write(`判断ボードへ登録しました（${result.decision.ref ? `${result.decision.ref} · ` : ''}${result.decision.id}）。社長の回答はこの会話に届きます。ここで手番を終えてください。\n`);
    else if (result.decision) write(`${result.decision.id}  ${result.decision.status}  ${result.decision.title}\n回答: ${result.decision.answer?.label ?? '未回答'}\n配達: ${result.decision.delivery?.state ?? '未回答'}\n`);
    else for (const r of result.items) write(`${r.ref ?? r.id}  ${r.status}  ${r.title}\n`);
    return 0;
  } catch (e) {
    const body = e instanceof BridgeError ? { code: e.code, message: e.message } : { code: 'internal_error', message: 'unexpected failure' };
    if (flags.json) write(`${JSON.stringify({ ok: false, error: body })}\n`);
    writeErr(`laa-bridge: ${body.code}: ${body.message}\n`);
    return exitCodeFor(e);
  }
}
