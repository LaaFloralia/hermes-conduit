import { resolveStateDir } from './config.mjs';
import { createPhoneUse } from './phone-use/service.mjs';
import { apnsSenderFromEnv } from './phone-use/apns.mjs';
import { BridgeError } from './errors.mjs';

export const PHONE_USE_USAGE = `laa-bridge phone-use — 使用中のiPhoneを操作する前に社長の許可を得る（laa-phoneが使う）
  phone-use ask --who <t> --purpose <t> [--timeout <s>] [--limit <s>] --json
            Dynamic Islandに許可・許可しないを出し、回答（allowed/denied/expired）まで待つ。
            APNS_KEY・APNS_KEY_IDは1Passwordの実行時注入で渡す。
  phone-use end <id> [--reason <t>] --json   操作の終了。表示を消す。
  phone-use status <id> --json
`;

export async function phoneUseCommand(argv, flags, io = {}) {
  const write = io.write ?? ((s) => process.stdout.write(s));
  const service = io.service ?? createPhoneUse({ dir: resolveStateDir(), push: apnsSenderFromEnv(io.env ?? process.env) });
  const usage = (message) => { throw new BridgeError(428, 'usage_error', message); };
  try {
    const [sub, id] = argv;
    if (!sub || sub === 'help') { write(PHONE_USE_USAGE); return 0; }
    const allowed = { ask: 'who purpose timeout limit json', end: 'reason json', status: 'json' };
    if (!allowed[sub]) usage('unknown phone-use subcommand');
    if (argv.length !== (sub === 'ask' ? 1 : 2)) usage('invalid positional arguments');
    for (const flag of Object.keys(flags)) if (!allowed[sub].split(' ').includes(flag)) usage(`unknown flag --${flag}`);
    const secondsFlag = (key, fallback) => {
      if (flags[key] === undefined) return fallback;
      const n = Number(flags[key]);
      if (!Number.isInteger(n) || n <= 0) usage(`--${key} is whole seconds`);
      return n * 1000;
    };
    let result;
    if (sub === 'ask') {
      if (typeof flags.who !== 'string' || typeof flags.purpose !== 'string') usage('--who and --purpose are required');
      const asked = await service.ask({ who: flags.who, purpose: flags.purpose,
        timeoutMs: secondsFlag('timeout', 90_000), limitMs: secondsFlag('limit', 1800_000) });
      result = asked.ok ? { ok: true, request: await service.waitForAnswer(asked.request.id) } : asked;
    } else if (sub === 'end') result = { ok: true, request: await service.end(id, { reason: typeof flags.reason === 'string' ? flags.reason.slice(0, 40) : 'done' }) };
    else result = { ok: true, request: service.status(id) };
    write(`${JSON.stringify(result)}\n`);
    return result.ok ? 0 : 1;
  } catch (e) {
    const body = e instanceof BridgeError ? { code: e.code, message: e.message } : { code: 'internal_error', message: 'unexpected failure' };
    write(`${JSON.stringify({ ok: false, error: body.code, detail: body.message })}\n`);
    return e instanceof BridgeError && e.status === 428 ? 2 : 1;
  }
}
