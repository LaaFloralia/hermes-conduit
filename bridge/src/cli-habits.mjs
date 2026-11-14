import { BridgeError } from './errors.mjs';
import { resolveStateDir } from './config.mjs';
import { createHabitStore } from './habits/store.mjs';
import { createHabitService } from './habits/service.mjs';

export const HABITS_USAGE = `laa-bridge habits — 週単位の習慣・禁止習慣（Asia/Tokyo、月曜始まり）

  habits week    [--week YYYY-MM-DD] [--json]
  habits history [--weeks N] [--json]
  habits events  [--limit N] [--json]
  habits add     --by <name> --reason <text> --request-id <id>
                 --kind do|avoid --title <text> --target N
                 [--minutes N] [--minimum <text>] [--note <text>] [--json]
  habits update  --id <uuid> --if-match <revision> --by <name> --reason <text>
                 [--title <text>] [--target N] [--minutes N | --clear-minutes]
                 [--minimum <text> | --clear-minimum] [--note <text>] [--json]
  habits archive --id <uuid> --if-match <revision> --by <name> --reason <text> [--json]
  habits restore --id <uuid> --if-match <revision> --by <name> --reason <text> [--json]
  habits check   --id <uuid> --date <YYYY-MM-DD|today> --by <name> --reason <text> [--json]
  habits uncheck --id <uuid> --date <YYYY-MM-DD|today> --by <name> --reason <text> [--json]

AIの経路では support: off の内容を返しません。作成時の支援は ask です。
Exit codes: 0 success, 1 unexpected, 2 usage, 3 not found, 4 conflict/support,
5 input rejected, 6 store unavailable.
`;

class UsageError extends Error {}
const usage = (message) => { throw new UsageError(message); };
const required = (flags, key) => {
  if (typeof flags[key] !== 'string' || !flags[key].trim()) usage(`--${key} is required`);
  return flags[key];
};

export function habitExitCode(error) {
  if (error instanceof UsageError) return 2;
  if (!(error instanceof BridgeError)) return 1;
  if (error.status >= 500 && error.code.startsWith('state_')) return 6;
  if (error.status === 404) return 3;
  if ([403, 409, 412].includes(error.status)) return 4;
  if (error.status === 428) return 2;
  if (error.status === 400) return 5;
  return 1;
}

export function habitsCommand(argv, flags, io = {}) {
  const write = io.write ?? ((text) => process.stdout.write(text));
  const writeErr = io.writeErr ?? ((text) => process.stderr.write(text));
  try {
    const sub = argv[0];
    if (!sub || sub === 'help') { write(HABITS_USAGE); return 0; }
    const common = 'id if-match by reason json';
    const allowed = {
      week: 'week json', history: 'weeks json', events: 'limit json',
      add: 'by reason request-id kind title target minutes minimum note json',
      update: `${common} title target minutes clear-minutes minimum clear-minimum note`,
      archive: common, restore: common,
      check: 'id date by reason json', uncheck: 'id date by reason json',
    };
    if (!allowed[sub]) usage(`unknown habits subcommand: ${sub}`);
    if (argv.length !== 1) usage('unexpected positional argument');
    for (const flag of Object.keys(flags)) if (!allowed[sub].split(' ').includes(flag)) usage(`unknown flag --${flag} for ${sub}`);
    const read = ['week', 'history', 'events'].includes(sub);
    const context = { actor: 'agent' };
    if (!read) {
      context.agent = required(flags, 'by');
      context.reason = required(flags, 'reason');
    }
    if (['update', 'archive', 'restore'].includes(sub)) required(flags, 'if-match');
    if (!read && sub !== 'add') required(flags, 'id');
    if (['check', 'uncheck'].includes(sub)) required(flags, 'date');
    const body = {};
    if (sub === 'add' || sub === 'update') {
      if (sub === 'add') {
        required(flags, 'request-id'); required(flags, 'kind'); required(flags, 'title'); required(flags, 'target');
        body.kind = flags.kind;
      }
      for (const field of ['title', 'minimum', 'note']) if (flags[field] !== undefined) body[field] = flags[field];
      for (const [flag, field] of [['target', 'weeklyTarget'], ['minutes', 'minutes']]) {
        if (flags[flag] !== undefined) body[field] = /^-?\d+$/.test(flags[flag]) ? Number(flags[flag]) : NaN;
      }
      for (const field of ['minutes', 'minimum']) if (flags[`clear-${field}`]) {
        if (flags[field] !== undefined) usage(`--${field} and --clear-${field} cannot be combined`);
        body[field] = null;
      }
      if (sub === 'update' && !Object.keys(body).length) usage('update needs at least one field');
    }
    const service = io.service ?? createHabitService({ store: createHabitStore({ dir: resolveStateDir() }) });
    let result;
    switch (sub) {
      case 'week': result = service.week({ ...context, week: flags.week }); break;
      case 'history': result = service.history({ ...context, weeks: flags.weeks }); break;
      case 'events': result = service.events({ ...context, limit: flags.limit }); break;
      case 'add': {
        const created = service.create({ ...context, principal: `cli:${context.agent}`, key: flags['request-id'], body });
        result = { habit: created.habit, replayed: created.replayed }; break;
      }
      case 'update': result = { habit: service.update({ ...context, id: flags.id, ifMatch: flags['if-match'], body }) }; break;
      case 'archive':
      case 'restore': result = { habit: service.update({ ...context, id: flags.id, ifMatch: flags['if-match'], body: { archived: sub === 'archive' } }) }; break;
      case 'check':
      case 'uncheck': result = service.check({ ...context, id: flags.id, date: flags.date === 'today' ? service.today() : flags.date, body: { done: sub === 'check' } }); break;
    }
    write(`${JSON.stringify({ ok: true, ...result }, null, flags.json ? undefined : 2)}\n`);
    return 0;
  } catch (error) {
    const body = error instanceof BridgeError ? { code: error.code, message: error.message, ...(error.details ? { details: error.details } : {}) }
      : error instanceof UsageError ? { code: 'usage_error', message: error.message }
        : { code: 'internal_error', message: 'unexpected failure' };
    if (flags.json) write(`${JSON.stringify({ ok: false, error: body })}\n`);
    writeErr(`laa-bridge: ${body.code}: ${body.message}\n`);
    return habitExitCode(error);
  }
}
