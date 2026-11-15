// The first instruction of a Work conversation, read from the provider's own
// transcript on this Mac (Claude Code, Codex, DSH), not from the daemon's
// timeline. The timeline is what the daemon holds now: after a restart or a
// compaction it can start partway through, so its first user entry was a
// later follow-up ("続行。…") that then stood as the first instruction.
//
// The transcript keeps every turn from the start. Its first user turn is the
// prompt `paseo run` (or Work) started the agent with; turns the harness
// injects — instructions files, reminders, runtime context, the naming
// notice — are skipped, and a `<paseo-system>` envelope from a parent agent is
// opened to the request inside it.
import { createReadStream, existsSync, readdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const UUID = /^[0-9a-f-]{36}$/i;
// DSH appends a zstd frame per write and marks some as skippable; Node's
// zstd stops at the first, the zstd tool reads them all.
const ZSTD = ['/opt/homebrew/bin/zstd', '/usr/local/bin/zstd', '/usr/bin/zstd'];
const run = promisify(execFile);
const INJECTED = [
  /^<system-reminder>/, /^# AGENTS\.md instructions/, /^<environment_context>/, /^<permissions instructions>/,
  /^<user_instructions>/, /^<INSTRUCTIONS>/, /^Current runtime context\./, /^会話名の自動整備：/,
  /^<command-name>/, /^<command-message>/, /^<local-command-/, /^Caveat: /, /^\[Request interrupted/,
];
const ENVELOPE = /^<paseo-system\b[^>]*>\n?([^]*?)\n?<\/paseo-system>\s*$/;
const ENTITIES = { '&quot;': '"', '&#39;': "'", '&apos;': "'", '&lt;': '<', '&gt;': '>', '&amp;': '&' };

export function promptText(raw) {
  if (typeof raw !== 'string') return null;
  let text = raw.trim();
  const envelope = text.match(ENVELOPE);
  if (envelope) text = envelope[1].replace(/&(?:quot|#39|apos|lt|gt|amp);/g, (entity) => ENTITIES[entity]).trim();
  if (!text || INJECTED.some((pattern) => pattern.test(text))) return null;
  return text;
}

const textOf = (content) => typeof content === 'string' ? content
  : Array.isArray(content) ? content.filter((part) => part?.type === 'text' || part?.type === 'input_text').map((part) => part.text).join('\n') : null;

async function firstLine(file, pick) {
  const lines = createInterface({ input: createReadStream(file, { encoding: 'utf8' }), crlfDelay: Infinity });
  try {
    for await (const line of lines) {
      let record;
      try { record = JSON.parse(line); } catch { continue; }
      const found = pick(record);
      if (found) return found;
    }
  } finally { lines.close(); }
  return null;
}

function claudeFile(home, sessionId, cwd) {
  const projects = join(home, '.claude', 'projects');
  if (cwd) {
    const direct = join(projects, cwd.replace(/[^A-Za-z0-9]/g, '-'), `${sessionId}.jsonl`);
    if (existsSync(direct)) return direct;
  }
  try {
    for (const dir of readdirSync(projects)) {
      const file = join(projects, dir, `${sessionId}.jsonl`);
      if (existsSync(file)) return file;
    }
  } catch { /* no Claude transcripts on this Mac */ }
  return null;
}

function codexFile(home, sessionId, createdAt) {
  const root = join(home, '.codex', 'sessions');
  const suffix = `-${sessionId}.jsonl`;
  const inDay = (day) => {
    try { return readdirSync(day).find((name) => name.startsWith('rollout-') && name.endsWith(suffix)) ?? null; } catch { return null; }
  };
  const created = Date.parse(createdAt ?? '');
  if (Number.isFinite(created)) {
    for (const offset of [0, -1, 1]) {
      const date = new Date(created + offset * 86_400_000);
      for (const parts of [[date.getFullYear(), date.getMonth() + 1, date.getDate()], [date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate()]]) {
        const day = join(root, String(parts[0]), String(parts[1]).padStart(2, '0'), String(parts[2]).padStart(2, '0'));
        const name = inDay(day);
        if (name) return join(day, name);
      }
    }
  }
  try {
    for (const year of readdirSync(root)) for (const month of readdirSync(join(root, year))) for (const date of readdirSync(join(root, year, month))) {
      const day = join(root, year, month, date);
      const name = inDay(day);
      if (name) return join(day, name);
    }
  } catch { /* no Codex transcripts */ }
  return null;
}

function dshFile(home, sessionId) {
  const root = join(home, '.dsh', 'sessions');
  try {
    for (const dir of readdirSync(root)) {
      const file = join(root, dir, sessionId, 'session.v4.jsonl.zstd');
      if (existsSync(file)) return file;
    }
  } catch { /* no DSH sessions */ }
  return null;
}

function paseoRecord(paseoHome, agentId) {
  const root = join(paseoHome, 'agents');
  try {
    for (const dir of readdirSync(root)) {
      const file = join(root, dir, `${agentId}.json`);
      if (existsSync(file)) return JSON.parse(readFileSync(file, 'utf8'));
    }
  } catch { /* the daemon's records are unavailable */ }
  return null;
}

// The LAA Work engine keeps the first instruction verbatim in the session's record.
function engineRecord(workState, agentId) {
  try {
    const file = join(workState, 'agents', `${agentId}.json`);
    return existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : null;
  } catch { return null; }
}

// `{ text, createdAt }` of the agent's first instruction, or null when its
// transcript is not on this Mac.
export async function readFirstPrompt(agentId, {
  paseoHome = process.env.PASEO_HOME ?? join(homedir(), '.paseo'), home = homedir(),
  workState = process.env.LAA_WORK_STATE ?? join(homedir(), '.local', 'state', 'laa-work'),
} = {}) {
  if (!UUID.test(agentId ?? '')) return null;
  const own = engineRecord(workState, agentId);
  if (own) {
    const text = promptText(own.initialPrompt);
    return text ? { text, createdAt: own.createdAt ?? null } : null;
  }
  const agent = paseoRecord(paseoHome, agentId);
  const persistence = agent?.persistence ?? agent?.runtimeInfo;
  const sessionId = persistence?.sessionId ?? persistence?.nativeHandle;
  if (!UUID.test(sessionId ?? '')) return null;
  const provider = persistence.provider ?? agent.provider;
  const cwd = persistence.metadata?.cwd ?? agent.cwd;
  try {
    if (provider === 'claude') {
      const file = claudeFile(home, sessionId, cwd);
      return file && await firstLine(file, (record) => {
        if (record.type !== 'user' || record.isMeta || record.isCompactSummary || record.message?.role !== 'user') return null;
        const text = promptText(textOf(record.message.content));
        return text && { text, createdAt: record.timestamp ?? null };
      });
    }
    if (provider === 'codex') {
      const file = codexFile(home, sessionId, agent.createdAt);
      return file && await firstLine(file, (record) => {
        const item = record.payload;
        if (record.type !== 'response_item' || item?.type !== 'message' || item.role !== 'user') return null;
        const text = promptText(textOf(item.content));
        return text && { text, createdAt: record.timestamp ?? null };
      });
    }
    if (provider === 'dsh') {
      const file = dshFile(home, sessionId);
      if (!file) return null;
      const zstd = ZSTD.find((path) => existsSync(path));
      if (!zstd) return null;
      const { stdout } = await run(zstd, ['-dcq', file], { maxBuffer: 256 * 1024 * 1024, encoding: 'utf8', timeout: 20_000 });
      const lines = stdout.split('\n');
      for (const line of lines) {
        let record;
        try { record = JSON.parse(line); } catch { continue; }
        const parts = record.type === 'agent/inbox/spliced' ? (record.data?.inserted ?? []).map((entry) => entry.content)
          : record.type === 'user/message' ? [record.data?.content] : [];
        for (const content of parts) {
          const text = promptText(textOf(content));
          if (text) return { text, createdAt: Number.isFinite(record.time) ? new Date(record.time).toISOString() : null };
        }
      }
    }
  } catch { /* unreadable transcript: no answer rather than a wrong one */ }
  return null;
}
