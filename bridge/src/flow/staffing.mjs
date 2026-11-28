// Who is consulted on a requirement. Deterministic on purpose: the same
// request always calls the same staff, so the choice costs no model call and
// can be tested. Roles come from hq/roles/roster.yaml (the `company:` line of
// each role); only `seat: member` roles are consulted — the chair is Monet and
// internal roles hold no seat (hq/tools/AI-OPERATING-MODEL.md).

import { readFileSync } from 'node:fs';

// A tiny reader for the roster's own shape (one `- id:` block per role, flow
// mappings on one line). Not a YAML parser: anything it does not recognise is skipped.
export function parseRoster(text) {
  const roles = [];
  let current = null;
  for (const line of String(text).split(/\r?\n/)) {
    const start = /^\s{2}-\s+id:\s*([a-z0-9_-]+)\s*(?:#.*)?$/.exec(line);
    if (start) {
      current = { id: start[1], name: start[1], title: '', seat: null, work: [], lens: '', confidential: false, status: null };
      roles.push(current);
      continue;
    }
    if (!current) continue;
    const field = /^\s{4}([a-z_]+):\s*(.*)$/.exec(line);
    if (!field) continue;
    const [, key, rest] = field;
    const value = rest.replace(/\s+#.*$/, '').trim();
    if (key === 'name' || key === 'title' || key === 'status') current[key] = value.replace(/^["']|["']$/g, '');
    else if (key === 'confidential') current.confidential = value === 'true';
    else if (key === 'company') {
      current.seat = /seat:\s*([a-z]+)/.exec(rest)?.[1] ?? null;
      current.work = (/work:\s*\[([^\]]*)\]/.exec(rest)?.[1] ?? '').split(',').map((item) => item.trim()).filter(Boolean);
      current.lens = /lens:\s*"([^"]*)"/.exec(rest)?.[1] ?? '';
    }
  }
  return roles;
}

export function readRoster(file) {
  try { return parseRoster(readFileSync(file, 'utf8')); } catch { return []; }
}

// What makes a role relevant: a risk flag the owner or Monet set, or wording of the request.
const RULES = [
  { id: 'cto', risk: ['architecture'], words: /実装|コード|アプリ|画面|バグ|不具合|修正|機能|API|配信|ビルド|テスト|bridge|repo|deploy|build|test|code|session|セッション|Mac|iPhone/iu,
    target: (request) => typeof request.repo === 'string' && request.repo.startsWith('/Users/laa/dev') },
  { id: 'cfo', risk: ['money'], words: /費用|課金|料金|契約|解約|請求|支払|税|会計|予算|サブスク|定額|freee|billing|cost|price/iu },
  { id: 'argus', risk: ['trade'], words: /トレード|売買|注文|口座|建玉|損切|MT5|チャート|Journal|trading|order|position/iu },
  { id: 'cso', risk: ['auth', 'external_send', 'delete'], words: /秘密|認証|権限|公開|送信|削除|消去|セキュリティ|パスワード|トークン|鍵|secret|token|auth|permission|publish/iu },
  { id: 'cio', risk: [], words: /調査|比較|リサーチ|市場|動向|出典|競合|research|survey|benchmark/iu },
  { id: 'cos', risk: [], words: /順番|優先|進捗|段取り|整理|依存|滞留|期限|backlog|手順|運用/iu },
];
// Filled in this order when the rules name too few: feasibility first, then ordering.
const FILL = ['cto', 'cos', 'cso', 'cio'];

export function pickStaff({ request, size = 'M', risk = [], roster = [], max = 4, min = 2 }) {
  const members = new Map(roster.filter((role) => role.seat === 'member').map((role) => [role.id, role]));
  const text = `${request?.title ?? ''}\n${request?.details ?? ''}`;
  const picked = [];
  const add = (id, why) => { if (members.has(id) && !picked.some((item) => item.role === id)) picked.push({ role: id, why }); };
  for (const rule of RULES) {
    const flagged = rule.risk.find((flag) => risk.includes(flag));
    if (flagged) add(rule.id, `risk:${flagged}`);
    else if (rule.target?.(request ?? {})) add(rule.id, 'target');
    else if (rule.words.test(text)) add(rule.id, 'wording');
  }
  // Risk-flagged roles are never dropped for room: sort them first, then cut.
  picked.sort((a, b) => Number(b.why.startsWith('risk:')) - Number(a.why.startsWith('risk:')));
  const cap = Math.min(Math.max(max, 1), 4, size === 'S' ? Math.max(min, 2) : 4);
  for (const id of FILL) { if (picked.length >= Math.min(min, cap)) break; add(id, 'fill'); }
  return picked.slice(0, cap).map(({ role, why }) => {
    const entry = members.get(role);
    // A confidential role (CFO) is told the title only, never the full details.
    return { role, profile: `laa-${role}`, name: entry.name, lens: entry.lens, titleOnly: entry.confidential === true, why };
  });
}
