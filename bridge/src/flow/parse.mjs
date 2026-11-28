// Parsers for the three bounded texts a model returns into the requirement
// flow: a staff member's meeting reply, the adviser's design and a session's
// hand-off slip (hq/roles/PROTOCOL.md). Models produce the text; this module
// alone decides whether it is usable, so the pipeline never acts on prose.

export const DESIGN_SCHEMA = 'laa.design.v1';
const SLIP_FIELDS = ['RESULT', 'CHANGED', 'VERIFIED', 'RESIDUAL', 'NEEDS_OWNER', 'MEMORY'];
const MEETING_FIELDS = ['POSITION', 'EVIDENCE', 'RISK', 'ALTERNATIVE', 'ASK'];
const MAX_PACKAGES = 8;
const MAX_REQUIREMENTS = 6;
const MAX_ACCEPTANCE = 12;
const PACKAGE_ID = /^[a-z][a-z0-9_-]{0,23}$/;

const bytes = (value) => Buffer.byteLength(value);
const clip = (value, chars) => { const all = [...value]; return all.length > chars ? `${all.slice(0, chars - 1).join('')}…` : value; };

// `FIELD: value` lines; a value runs until the next known field. Unknown text
// before the first field is ignored (a model's greeting is not data).
function labelled(text, names) {
  const out = {};
  if (typeof text !== 'string') return out;
  const pattern = new RegExp(`^\\s*(?:[-*]\\s*)?\\**(${names.join('|')})\\**\\s*[:：]\\s*`, 'u');
  let current = null;
  for (const line of text.split(/\r?\n/)) {
    const match = pattern.exec(line);
    if (match) {
      current = match[1];
      // The last occurrence wins: a session that corrects its slip is read as corrected.
      out[current] = line.slice(match[0].length).trim();
    } else if (current && line.trim() && !/^```/.test(line.trim())) {
      out[current] = `${out[current]}\n${line.trim()}`.trim();
    } else if (!line.trim()) {
      current = null;
    }
  }
  return out;
}

// The hand-off slip. `result` is the session's own claim, never a verdict.
export function parseSlip(text) {
  const found = labelled(text, SLIP_FIELDS);
  const slip = Object.fromEntries(SLIP_FIELDS.filter((name) => name !== 'MEMORY').map((name) => [name, clip(found[name] ?? '', 1200)]));
  const result = /^(done|partial|blocked)\b/i.exec(slip.RESULT)?.[1].toLowerCase() ?? null;
  return { present: result !== null, result, slip, needsOwner: Boolean(slip.NEEDS_OWNER) && !/^(none|なし|no)\b/i.test(slip.NEEDS_OWNER) };
}

// A staff member's contribution: the PROTOCOL meeting block plus what the
// requirement flow asks on top of it (scope and acceptance bullets).
export function parseMeetingReply(text) {
  const found = labelled(text, [...MEETING_FIELDS, 'SCOPE', 'ACCEPTANCE']);
  const acceptance = (found.ACCEPTANCE ?? '').split('\n').map((line) => line.replace(/^\s*(?:[-*・]|\d+[.)])\s*/u, '').trim())
    .filter((line) => line && !/^(none|なし)$/i.test(line)).map((line) => clip(line, 100)).slice(0, 6);
  const field = (name, chars) => clip(found[name] ?? '', chars);
  const reply = { position: field('POSITION', 400), evidence: field('EVIDENCE', 600), risk: field('RISK', 400),
    alternative: field('ALTERNATIVE', 400), ask: field('ASK', 300), scope: field('SCOPE', 400), acceptance };
  return { ok: Boolean(reply.position || reply.risk || acceptance.length), reply };
}

function lastFencedJson(text, marker) {
  if (typeof text !== 'string') return null;
  const blocks = [...text.matchAll(/```(?:json)?\s*\n([\s\S]*?)\n\s*```/g)].map((match) => match[1]);
  // A reply that is nothing but the object is accepted too.
  if (!blocks.length && text.trim().startsWith('{')) blocks.push(text.trim());
  for (const block of blocks.reverse()) {
    if (!block.includes(marker)) continue;
    try {
      const parsed = JSON.parse(block);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
    } catch { /* The next block may be the valid one. */ }
  }
  return null;
}

const str = (value, field, maxBytes, { optional = false } = {}) => {
  if (value == null || value === '') {
    if (optional) return '';
    throw new Error(`${field}_required`);
  }
  if (typeof value !== 'string' || value.includes('\0') || bytes(value) > maxBytes) throw new Error(`${field}_invalid`);
  return value.trim();
};

// The adviser's `laa.design.v1` block. Returns { ok, design } or { ok:false, error }
// with a short machine code the pipeline can send back once for a repair.
export function parseDesign(text, { allowedProfiles = null, defaultProfile = null, root = '/Users/laa' } = {}) {
  const raw = lastFencedJson(text, DESIGN_SCHEMA);
  if (!raw || raw.schema !== DESIGN_SCHEMA) return { ok: false, error: 'design_block_missing' };
  try {
    if (!Array.isArray(raw.requirements) || raw.requirements.length < 1 || raw.requirements.length > MAX_REQUIREMENTS) throw new Error('requirements_count_invalid');
    const requirements = raw.requirements.map((item, index) => {
      if (!item || typeof item !== 'object') throw new Error('requirement_invalid');
      if (!Array.isArray(item.acceptance) || item.acceptance.length < 1 || item.acceptance.length > MAX_ACCEPTANCE) throw new Error(`requirement_${index}_acceptance_count_invalid`);
      const acceptance = item.acceptance.map((entry, at) => ({
        id: typeof entry?.id === 'string' && /^[A-Za-z0-9_-]{1,24}$/.test(entry.id) ? entry.id : `a${at + 1}`,
        text: str(entry?.text, 'acceptance_text', 300), check: str(entry?.check, 'acceptance_check', 600, { optional: true }) || null,
      }));
      if (new Set(acceptance.map((entry) => entry.id)).size !== acceptance.length) throw new Error('acceptance_ids_not_distinct');
      return { title: str(item.title, 'requirement_title', 600), details: str(item.details, 'requirement_details', 8192, { optional: true }) || null, acceptance };
    });
    if (!Array.isArray(raw.packages) || raw.packages.length < 1 || raw.packages.length > MAX_PACKAGES) throw new Error('packages_count_invalid');
    const packages = raw.packages.map((item) => {
      if (!item || typeof item !== 'object' || typeof item.id !== 'string' || !PACKAGE_ID.test(item.id)) throw new Error('package_id_invalid');
      const requirement = item.requirement ?? 0;
      if (!Number.isInteger(requirement) || requirement < 0 || requirement >= requirements.length) throw new Error(`package_${item.id}_requirement_invalid`);
      // A model may not pick a route the registry does not offer to this flow:
      // an unknown or retired profile falls back to the configured default.
      const profile = allowedProfiles && !allowedProfiles.includes(item.profile) ? defaultProfile : (item.profile ?? defaultProfile);
      const repo = item.repo == null || item.repo === '' ? null : str(item.repo, 'package_repo', 400);
      if (repo !== null && !(repo === root || repo.startsWith(`${root}/`)) ) throw new Error(`package_${item.id}_repo_outside_root`);
      if (repo !== null && repo.split('/').includes('..')) throw new Error(`package_${item.id}_repo_invalid`);
      const owns = item.owns ?? [];
      if (!Array.isArray(owns) || owns.length > 30 || !owns.every((entry) => typeof entry === 'string' && entry && bytes(entry) <= 300)) throw new Error(`package_${item.id}_owns_invalid`);
      const after = item.after ?? [];
      if (!Array.isArray(after) || !after.every((entry) => typeof entry === 'string')) throw new Error(`package_${item.id}_after_invalid`);
      return { id: item.id, requirement, title: str(item.title, 'package_title', 200), profile, requestedProfile: item.profile ?? null, repo, owns, after: [...new Set(after)],
        purpose: str(item.purpose, 'package_purpose', 1500), completion: str(item.completion, 'package_completion', 1500),
        scope: str(item.scope, 'package_scope', 1500), prompt: str(item.prompt, 'package_prompt', 6000),
        verification: str(item.verification, 'package_verification', 1500, { optional: true }) };
    });
    const ids = new Set(packages.map((item) => item.id));
    if (ids.size !== packages.length) throw new Error('package_ids_not_distinct');
    for (const item of packages) if (item.after.some((id) => !ids.has(id) || id === item.id)) throw new Error(`package_${item.id}_after_unknown`);
    if (hasCycle(packages)) throw new Error('package_order_cycle');
    for (const [index] of requirements.entries()) if (!packages.some((item) => item.requirement === index)) throw new Error(`requirement_${index}_has_no_package`);
    const ownerDecisions = (raw.ownerDecisions ?? []).slice(0, 4).map((item) => {
      const options = Array.isArray(item?.options) ? item.options.map((option) => str(option, 'decision_option', 240)) : [];
      if (options.length < 2 || options.length > 6) throw new Error('decision_options_invalid');
      const recommended = Number.isInteger(item.recommended) && item.recommended >= 0 && item.recommended < options.length ? item.recommended : 0;
      return { title: str(item.title, 'decision_title', 180), summary: str(item.summary, 'decision_summary', 1800, { optional: true }), options, recommended,
        impact: str(item.impact, 'decision_impact', 600, { optional: true }) };
    });
    const risks = (Array.isArray(raw.risks) ? raw.risks : []).filter((item) => typeof item === 'string' && item.trim()).slice(0, 8).map((item) => clip(item.trim(), 300));
    return { ok: true, design: { schema: DESIGN_SCHEMA, summary: clip(str(raw.summary, 'summary', 2400), 600), requirements, packages, risks, ownerDecisions } };
  } catch (error) {
    return { ok: false, error: String(error.message).slice(0, 80) };
  }
}

function hasCycle(packages) {
  const after = new Map(packages.map((item) => [item.id, item.after]));
  const state = new Map();
  const visit = (id) => {
    if (state.get(id) === 'done') return false;
    if (state.get(id) === 'open') return true;
    state.set(id, 'open');
    if ((after.get(id) ?? []).some(visit)) return true;
    state.set(id, 'done');
    return false;
  };
  return packages.some((item) => visit(item.id));
}

const VERDICTS = new Set(['verified', 'rework', 'needs_owner', 'not_mine', 'noted']);

// Monet's verdict on one inbox event. Thrown codes are short and safe to show.
export function parseVerdict(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || !VERDICTS.has(raw.verdict)) throw new Error('verdict_invalid');
  if (Object.keys(raw).some((key) => !['verdict', 'acceptance', 'note', 'followup', 'decision', 'report'].includes(key))) throw new Error('verdict_field_unknown');
  const note = raw.note == null ? null : String(raw.note);
  if (note !== null && (!note.trim() || [...note].length > 200 || /[\r\n\u2028\u2029\0]/u.test(note))) throw new Error('verdict_note_invalid');
  const acceptance = (raw.acceptance ?? []).map((item) => {
    if (!item || typeof item.id !== 'string' || !['passed', 'failed'].includes(item.status)) throw new Error('verdict_acceptance_invalid');
    const itemNote = item.note == null ? null : String(item.note);
    if (itemNote !== null && (!itemNote.trim() || [...itemNote].length > 200 || /[\r\n\u2028\u2029\0]/u.test(itemNote))) throw new Error('verdict_acceptance_note_invalid');
    return { id: item.id, status: item.status, note: itemNote };
  });
  if (raw.verdict === 'verified') {
    if (!note) throw new Error('verdict_note_required');
    if (acceptance.some((item) => item.status === 'failed')) throw new Error('verdict_verified_with_failed_item');
  }
  const followup = raw.followup == null ? null : str(raw.followup, 'verdict_followup', 6000);
  if (raw.verdict === 'rework' && !followup) throw new Error('verdict_followup_required');
  let decision = null;
  if (raw.verdict === 'needs_owner') {
    const d = raw.decision;
    const options = Array.isArray(d?.options) ? d.options.map((option) => str(typeof option === 'string' ? option : option?.label, 'decision_option', 240)) : [];
    if (!d || options.length < 2 || options.length > 6) throw new Error('verdict_decision_required');
    decision = { title: str(d.title, 'decision_title', 180), summary: str(d.summary ?? note ?? d.title, 'decision_summary', 1800), options,
      recommended: Number.isInteger(d.recommended) && d.recommended >= 0 && d.recommended < options.length ? d.recommended : 0,
      impact: str(d.impact, 'decision_impact', 600) };
  }
  // Three short lines for the single report to the owner; optional, used on the last verdict.
  const report = raw.report == null ? null : Object.fromEntries(['result', 'verification', 'residual'].map((key) => [key, clip(String(raw.report?.[key] ?? '').replace(/\s+/gu, ' ').trim(), 200)]));
  return { verdict: raw.verdict, acceptance, note, followup, decision, report };
}
