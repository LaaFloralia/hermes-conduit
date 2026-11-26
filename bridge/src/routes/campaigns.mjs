// Campaigns are read from campaign-hunt's `list` and choices from `decide`.
// The Bridge never opens the ledger or the owner's profile. The wire contract
// requires confirmed eligibility; neither receipts nor reason codes leave the ledger.
import { execFile } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { BridgeError, badRequest } from '../errors.mjs';
import { parseObjectBody } from './state-file.mjs';

const exec = promisify(execFile);
const KEY = /^[0-9a-f]{16}$/;
const KIND = /^[a-z][a-z0-9_]{0,23}$/;
const CATEGORY = /^[a-z][a-z0-9_]{0,23}$/;
const ACTIONS = { site: 'agent_apply', x: 'self', grant: 'draft' };
const WAITING = new Set(['needs_owner', 'candidate']);
const DECIDED = new Set(['approved', 'declined', 'drafted']);
const VISIBLE = new Set([...WAITING, ...DECIDED, 'applied', 'listed']);
const STATUS_FILTERS = new Set(['current', 'applied', 'all']);
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
const japanDate = new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Tokyo', year: 'numeric', month: '2-digit', day: '2-digit' });
const searchText = (value) => value.normalize('NFKC').trim().toLowerCase();

function expired(deadline, today) {
  if (typeof deadline !== 'string') return false;
  const iso = /^(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)/.exec(deadline);
  const japanese = /^(\d{1,2})月(\d{1,2})日/.exec(deadline);
  if (!iso && !japanese) return false;
  const [year, month, day] = (iso?.slice(1) ?? [today.slice(0, 4), ...japanese.slice(1)]).map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day
    && date.toISOString().slice(0, 10) < today;
}

/** One verified, live row as the app reads it; never forward unverified rows. */
export function campaignItem(raw, today = japanDate.format(new Date())) {
  if (!raw || typeof raw !== 'object' || raw.eligible !== true || !KEY.test(raw.key ?? '') || expired(raw.deadline, today)) return null;
  const kind = raw.kind ?? 'site';
  if (typeof kind !== 'string' || !KIND.test(kind) || !VISIBLE.has(raw.status) || ((kind === 'deal') !== (raw.status === 'listed'))) return null;
  const title = text(raw.title);
  const url = webURL(raw.url);
  if (!title || !url) return null;
  const item = {
    key: raw.key, kind, action: kind === 'deal' ? 'browse' : KIND.test(raw.action ?? '') ? raw.action : ACTIONS[kind] ?? null,
    category: CATEGORY.test(raw.category ?? '') ? raw.category : ['grant', 'deal'].includes(kind) ? kind : 'prize',
    categoryLabel: text(raw.category_label), genre: text(raw.genre), service: text(raw.service),
    addedAt: text(raw.added_at) ?? text(raw.at), status: raw.status, waiting: WAITING.has(raw.status), eligible: true, url,
    benefit: text(raw.benefit) ?? text(raw.prize), nextStep: text(raw.next_step),
    gbizid: typeof raw.gbizid === 'boolean' ? raw.gbizid : null,
    at: text(raw.at), decidedAt: text(raw.decided_at),
  };
  for (const field of TEXT_FIELDS) item[field] = field === 'title' ? title : text(raw[field]);
  return item;
}

export function campaignRoutes({ command = defaultCampaignCommand(), run = exec, timeoutMs = 20_000, now = () => new Date() } = {}) {
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
    const query = new URL(req.url, 'http://bridge').searchParams;
    const status = query.get('status') ?? 'current';
    const q = searchText(query.get('q') ?? '');
    const wanted = query.get('kind') ?? (query.has('status') || query.has('q') ? 'all' : 'site');
    if (!KIND.test(wanted)) throw badRequest('kind_invalid', 'kind must be all or a kind name');
    if (!STATUS_FILTERS.has(status)) throw badRequest('status_invalid', 'status must be current, applied or all');
    const result = await ledger(['list']);
    if (result?.version !== 4 || !Array.isArray(result.items)) throw unavailable('the campaign ledger must support verified rows');
    const today = japanDate.format(now());
    const items = result.items.map((item) => campaignItem(item, today)).filter(Boolean)
      .filter((item) => (wanted === 'all' || item.kind === wanted) &&
        (status === 'all' || (item.status === 'applied') === (status === 'applied')) &&
        (!q || [item.title, item.organizer, item.benefit, item.categoryLabel, item.genre, item.service, item.url]
          .some((value) => value && searchText(value).includes(q))));
    const present = new Map(items.map((item) => [item.category, item.categoryLabel]));
    // Take the category ordering and labels from the ledger; never advertise a
    // category supplied only by a rejected row.
    const categories = [];
    for (const row of Array.isArray(result.categories) ? result.categories : []) {
      if (present.has(row?.category)) {
        categories.push({ category: row.category, label: text(row.category_label) ?? present.get(row.category) });
        present.delete(row.category);
      }
    }
    for (const [category, label] of present) categories.push({ category, label });
    return { status: 200, data: { count: items.filter((item) => item.waiting).length, items, categories } };
  }

  async function decide({ params, rawBody }) {
    const body = parseObjectBody(rawBody);
    if (Object.keys(body).some((key) => key !== 'choice' && key !== 'kind')) throw badRequest('payload_invalid', 'only choice and kind are accepted');
    if (!CHOICES.has(body.choice)) throw badRequest('payload_invalid', 'choice must be approve or decline');
    if (body.kind !== undefined && (typeof body.kind !== 'string' || !KIND.test(body.kind))) throw badRequest('payload_invalid', 'kind must be a kind name');
    if (body.kind === 'deal') throw new BridgeError(409, 'campaign_not_pending', 'deals do not take a decision');
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
