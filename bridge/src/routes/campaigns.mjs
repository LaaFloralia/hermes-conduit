// Campaign entries that wait for the owner, and the owner's choice on each.
//
// The campaign-hunt skill owns the ledger; the Bridge never reads or writes
// the file itself. It runs the skill's two commands (`ledger.py pending --all`
// and `ledger.py decide <key> approve|decline --kind <kind>`) and passes their
// JSON on, so one program keeps the ledger's rules. The ledger holds no
// personal details: the skill refuses them when a row is recorded.
//
// Three kinds wait for the owner, each with its own meaning of "approve":
// `site` (the routine applies at its next run), `x` (the owner applies on X)
// and `grant` (the routine drafts the application). An app that predates the
// kinds asks without `kind=all` and receives only `site`, the one it labels
// correctly.
//
// Decisions run one at a time, because each appends a line to the same file.
import { execFile } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { BridgeError, badRequest } from '../errors.mjs';
import { parseObjectBody } from './state-file.mjs';

const exec = promisify(execFile);
const KEY = /^[0-9a-f]{16}$/;
const KINDS = new Set(['site', 'x', 'grant']);
const ACTIONS = { site: 'agent_apply', x: 'self', grant: 'draft' };
const WAITING = new Set(['needs_owner', 'candidate']);
const DECIDED = new Set(['approved', 'declined', 'drafted']);
const CHOICES = new Set(['approve', 'decline']);
const TEXT_FIELDS = ['title', 'organizer', 'deadline', 'reason', 'conditions'];

export function defaultCampaignCommand(env = process.env) {
  const script = env.LAA_CAMPAIGN_LEDGER ?? join(homedir(), '.agents/skills/campaign-hunt/scripts/ledger.py');
  return [env.LAA_CAMPAIGN_PYTHON ?? '/usr/bin/python3', script];
}

const text = (value) => typeof value === 'string' && value.trim() !== '' ? value.slice(0, 2000) : null;
const webURL = (value) => {
  if (typeof value !== 'string') return null;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : null;
  } catch { return null; }
};
const unavailable = (message) => new BridgeError(503, 'campaigns_unavailable', message, { retryable: true });

/** One row as the app reads it; an unusable row is dropped rather than failing the list. */
export function campaignItem(raw) {
  if (!raw || typeof raw !== 'object' || !KEY.test(raw.key ?? '')) return null;
  // Version 1 of the ledger's output had no kind: every row was a site entry.
  const kind = raw.kind ?? 'site';
  if (!KINDS.has(kind) || !(WAITING.has(raw.status) || DECIDED.has(raw.status))) return null;
  const title = text(raw.title);
  const url = webURL(raw.url);
  if (!title || !url) return null;
  const item = {
    key: raw.key, kind, action: ACTIONS[kind], status: raw.status, waiting: WAITING.has(raw.status), url,
    benefit: text(raw.benefit) ?? text(raw.prize), nextStep: text(raw.next_step),
    gbizid: typeof raw.gbizid === 'boolean' ? raw.gbizid : null,
    at: text(raw.at), decidedAt: text(raw.decided_at),
  };
  for (const field of TEXT_FIELDS) item[field] = field === 'title' ? title : text(raw[field]);
  return item;
}

export function campaignRoutes({ command = defaultCampaignCommand(), run = exec, timeoutMs = 20_000 } = {}) {
  let queue = Promise.resolve();

  async function ledger(args) {
    const [file, ...prefix] = command;
    let stdout;
    try {
      ({ stdout } = await run(file, [...prefix, ...args], { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024, encoding: 'utf8' }));
    } catch (error) {
      const message = `${error?.stderr ?? ''}${error?.stdout ?? ''}`;
      if (/NOT_FOUND/.test(message)) throw new BridgeError(404, 'campaign_not_found', 'no campaign entry has this key');
      if (/NOT_PENDING/.test(message)) throw new BridgeError(409, 'campaign_not_pending', 'this campaign entry is not waiting for the owner');
      if (/AMBIGUOUS/.test(message)) throw new BridgeError(409, 'campaign_kind_required', 'this key names more than one kind; send kind');
      throw unavailable('the campaign ledger cannot be read');
    }
    try { return JSON.parse(stdout); } catch { throw unavailable('the campaign ledger returned unreadable output'); }
  }

  async function list({ req }) {
    const wanted = new URL(req.url, 'http://bridge').searchParams.get('kind');
    if (wanted !== null && wanted !== 'all' && !KINDS.has(wanted)) throw badRequest('kind_invalid', 'kind must be all, site, x or grant');
    const result = await ledger(['pending', '--all']);
    if (!Array.isArray(result?.items)) throw unavailable('the campaign ledger returned unreadable output');
    const items = result.items.map(campaignItem).filter(Boolean)
      .filter((item) => wanted === 'all' || item.kind === (wanted ?? 'site'));
    return { status: 200, data: { count: items.filter((item) => item.waiting).length, items } };
  }

  async function decide({ params, rawBody }) {
    const body = parseObjectBody(rawBody);
    if (Object.keys(body).some((key) => key !== 'choice' && key !== 'kind')) throw badRequest('payload_invalid', 'only choice and kind are accepted');
    if (!CHOICES.has(body.choice)) throw badRequest('payload_invalid', 'choice must be approve or decline');
    if (body.kind !== undefined && !KINDS.has(body.kind)) throw badRequest('payload_invalid', 'kind must be site, x or grant');
    const args = ['decide', params[0], body.choice, ...(body.kind ? ['--kind', body.kind] : [])];
    const step = queue.then(() => ledger(args));
    queue = step.catch(() => {});
    const result = await step;
    if (result?.key !== params[0] || !DECIDED.has(result.status)) throw unavailable('the campaign ledger returned unreadable output');
    return { status: 200, data: { key: result.key, kind: result.kind ?? body.kind ?? 'site', status: result.status, decidedAt: text(result.decided_at) } };
  }

  return [
    { method: 'GET', path: '/v1/campaigns', auth: true, scope: 'sessions:read', handler: list },
    // Choosing the same option twice records the same state, so a failed
    // attempt frees its key and the app may simply send the choice again.
    { method: 'POST', pattern: /^\/v1\/campaigns\/([0-9a-f]{16})\/decide$/, auth: true, scope: 'sessions:write', idempotent: true,
      releaseOnError: () => true, handler: decide },
  ];
}
