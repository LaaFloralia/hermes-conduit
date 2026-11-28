// The fixed texts the requirement flow sends to models. AI-to-AI text is
// English and structured (hq/tools/AI-OPERATING-MODEL.md); what reaches the
// owner — requirement titles, acceptance items, decision options, report lines —
// stays Japanese. Every template is a pure function of the flow record, so a
// retried step sends byte-identical text and the session layer's request
// digest recognises it as the same request.

import { DESIGN_SCHEMA } from './parse.mjs';

const clip = (value, chars) => { const all = [...String(value ?? '')]; return all.length > chars ? `${all.slice(0, chars - 1).join('')}…` : all.join(''); };
const block = (value) => String(value ?? '').trim() || '(none)';
// Cut on a character boundary so the text stays inside a byte limit (the session layer counts bytes).
export function clipBytes(value, maxBytes) {
  const text = String(value ?? '');
  if (Buffer.byteLength(text) <= maxBytes) return text;
  let out = '', size = 0;
  for (const ch of text) {
    const add = Buffer.byteLength(ch);
    if (size + add > maxBytes - 3) break;
    out += ch; size += add;
  }
  return `${out}…`;
}
const PROMPT_BYTES = 15_500, FIELD_BYTES = 1_900;

export function staffPrompt({ member, flow }) {
  const { request, size, risk } = flow;
  const details = member.titleOnly ? '(withheld: you receive the title only)' : block(clipBytes(request.details, 6000));
  return [
    `You are consulted as ${member.name} (${member.role}) on one owner requirement, before it is designed. Answer from your specialty only: ${member.lens || 'your role'}.`,
    'This is a single reply. Do not start work, do not dispatch anything, do not ask the owner. If you lack a fact, mark it UNVERIFIED.',
    '',
    `REQUIREMENT TITLE: ${clip(request.title, 600)}`,
    `DETAILS: ${details}`,
    `SIZE: ${size}   RISK FLAGS: ${risk.length ? risk.join(', ') : 'none'}`,
    request.repo ? `TARGET: ${request.repo}` : null,
    '',
    'Reply with exactly these fields, one per line, nothing before or after:',
    'POSITION: <go | change | stop — one sentence from your specialty; say "disagree with <who>: <what>" when you disagree>',
    'EVIDENCE: <facts you checked, with source; mark UNVERIFIED>',
    'SCOPE: <what must be inside and what must stay outside this requirement, from your specialty>',
    'RISK: <the main risk and how it would show>',
    'ALTERNATIVE: <a concrete alternative, or none>',
    'ASK: <one question for the chair, or none>',
    'ACCEPTANCE:',
    '- <an observable result that proves the requirement is met, in Japanese, one line>',
    '- <up to four more, each checkable by a command or by looking at something>',
  ].filter((line) => line !== null).join('\n');
}

function staffDigest(flow) {
  const rows = (flow.staff ?? []).filter((row) => row.state === 'done');
  if (!rows.length) return '(no staff contribution was returned)';
  return rows.map((row) => [
    `- ${row.role}: ${block(row.position)}`,
    row.scope ? `  scope: ${row.scope}` : null,
    row.risk ? `  risk: ${row.risk}` : null,
    row.alternative && !/^none$/i.test(row.alternative) ? `  alternative: ${row.alternative}` : null,
    row.ask && !/^none$/i.test(row.ask) ? `  ask: ${row.ask}` : null,
    ...(row.acceptance ?? []).map((line) => `  acceptance: ${line}`),
  ].filter(Boolean).join('\n')).join('\n');
}

const designExample = (profiles) => JSON.stringify({
  schema: DESIGN_SCHEMA, summary: '≤600 chars, Japanese',
  requirements: [{ title: 'the owner\'s words for requirement 0; a new Japanese title for any added one', details: 'what will be true when done (Japanese)',
    acceptance: [{ id: 'a1', text: 'observable result (Japanese, ≤300 bytes)', check: 'command to run or what to look at (≤600 bytes)' }] }],
  packages: [{ id: 'wp1', requirement: 0, title: '対象｜作業', profile: profiles.join(' | '), repo: '/Users/laa/dev/<repo> or null', owns: ['path/**'], after: [],
    purpose: 'why this package exists', completion: 'the done condition', scope: 'inputs, what may and may not be touched',
    verification: 'the checks the session must run before returning', prompt: 'the full task for the implementation session' }],
  risks: ['…'], ownerDecisions: [{ title: '日本語', summary: '日本語', options: ['案A', '案B'], recommended: 0, impact: '【任せられる】… or 【必ず社長：ブランドの好み】…' }],
}, null, 1);

export function advisorTask({ flow, config }) {
  const { request, size, risk } = flow;
  const profiles = config.implementation.allowedProfiles;
  const prompt = [
    'You are the design adviser for one owner requirement. Produce the design that implementation sessions will be dispatched from. Read what you need (repositories, project rules, existing code) before deciding; do not implement, do not dispatch, do not edit files.',
    '',
    `REQUIREMENT TITLE (the owner's words, keep them as requirement 0's title): ${clip(request.title, 600)}`,
    `DETAILS: ${block(clipBytes(request.details, 5000))}`,
    request.ownerText && request.ownerText !== request.details ? `OWNER TEXT (verbatim): ${clipBytes(request.ownerText, 2500)}` : null,
    `SIZE: ${size}   RISK FLAGS: ${risk.length ? risk.join(', ') : 'none'}`,
    request.repo ? `TARGET: ${request.repo}` : null,
    '',
    'STAFF CONTRIBUTIONS (scope, risks, acceptance candidates — weigh them, you are not bound by them):',
    clipBytes(staffDigest(flow), 3500),
    '',
    'RULES',
    `- Split the work into 1–8 packages that can each be given to one implementation session. Each package names the files it owns; two packages never own the same file. Use "after" for real dependencies only.`,
    `- "profile" is one of: ${profiles.join(', ')}. Default ${config.implementation.defaultProfile}; use a DeepSeek profile for procedure-defined work with clear checks. No other route exists for this flow.`,
    '- Every requirement carries 1–12 acceptance items a verifier can check without asking anyone: an observable result plus the command or the thing to look at.',
    '- Put a choice only the owner or Monet can make in ownerDecisions (2–6 options, one recommended). Do not ask for confirmation of ordinary engineering choices.',
    '- Trading: never design order placement, modification or live-account switches. Secrets: never put one in a prompt.',
    '',
    `End your reply with exactly one fenced json block of schema ${DESIGN_SCHEMA}, shaped like this:`,
    '```json',
    designExample(profiles),
    '```',
  ].filter((line) => line !== null).join('\n');
  return {
    purpose: 'Design one owner requirement: requirements with acceptance criteria and implementation packages.',
    completion: `The reply ends with one valid ${DESIGN_SCHEMA} JSON block. Nothing is implemented or dispatched.`,
    scope: 'Read-only investigation of the target. No file edits, no sessions, no messages to the owner.',
    returnTo: 'The Bridge requirement flow (it parses the JSON block).',
    prompt: clipBytes(prompt, PROMPT_BYTES),
  };
}

// Sent once when the adviser's reply could not be parsed.
export function advisorRepair(error) {
  return `Your reply could not be used: ${error}. Reply again with exactly one fenced json block of schema ${DESIGN_SCHEMA} as specified in the task, and nothing after it.`;
}

// The brief of one implementation session: task, inputs, owned files, done
// condition, verification and return format (hq/tools/PERSONAL-AGENT.md fields).
export function packageTask({ pkg, design, requirement, decisions = [] }) {
  const acceptance = (requirement?.acceptance ?? []).map((item) => `- ${item.id}: ${item.text}${item.check ? ` — check: ${item.check}` : ''}`).join('\n');
  const answered = decisions.filter((item) => item.answer).map((item) => `- ${item.title}: ${item.answer}`).join('\n');
  const prompt = [
    `TASK: ${pkg.title}`,
    block(pkg.prompt),
    '',
    'INPUTS',
    `- Requirement: ${clip(requirement?.title ?? '', 600)}`,
    design?.summary ? `- Design summary: ${design.summary}` : null,
    pkg.repo ? `- Repository: ${pkg.repo} (use this absolute path; the working directory is /Users/laa)` : null,
    pkg.after?.length ? `- Depends on packages already verified: ${pkg.after.join(', ')}` : null,
    answered ? `- Decisions already made:\n${answered}` : null,
    '',
    'OWNED FILES (edit nothing else; if another file must change, make the smallest edit and say so in CHANGED)',
    ...(pkg.owns?.length ? pkg.owns.map((path) => `- ${path}`) : ['- (none named: stay inside the task\'s target)']),
    '',
    `DONE CONDITION: ${block(pkg.completion)}`,
    acceptance ? `ACCEPTANCE ITEMS THIS WORK IS CHECKED AGAINST\n${acceptance}` : null,
    `VERIFICATION YOU MUST RUN BEFORE RETURNING: ${block(pkg.verification || 'Run the acceptance checks you can run and state each outcome.')}`,
    '',
    'RETURN FORMAT — end your last message with this hand-off slip (hq/roles/PROTOCOL.md). RESULT is your claim; Monet verifies CHANGED and VERIFIED against the real thing.',
    'RESULT: done | partial | blocked',
    'CHANGED: <path or artifact — sha or version>',
    'VERIFIED: <check — command or observation — outcome; NOT RUN if not run>',
    'RESIDUAL: <what remains and the next step>',
    'NEEDS_OWNER: <class — question — options — recommended, or none>',
  ].filter((line) => line !== null).join('\n');
  return {
    purpose: clipBytes(pkg.purpose, FIELD_BYTES), completion: clipBytes(pkg.completion, FIELD_BYTES), scope: clipBytes(pkg.scope, FIELD_BYTES),
    returnTo: 'Monet through the Bridge inbox: finish your turn with the hand-off slip; do not message the owner.',
    prompt: clipBytes(prompt, PROMPT_BYTES),
  };
}

// The design used when no adviser is consulted (size S without a risk flag):
// the request itself plus the acceptance bullets the staff proposed.
export function synthesizeDesign({ flow, config }) {
  const bullets = [...new Set((flow.staff ?? []).flatMap((row) => row.acceptance ?? []))].slice(0, 12);
  const acceptance = (bullets.length ? bullets : ['依頼した結果が実物で確認できる']).map((text, index) => ({ id: `a${index + 1}`, text, check: null }));
  const notes = (flow.staff ?? []).filter((row) => row.state === 'done').map((row) => `- ${row.role}: ${[row.scope, row.risk].filter(Boolean).join(' / ')}`).join('\n');
  const { request } = flow;
  return {
    schema: DESIGN_SCHEMA, summary: clip(request.title, 600),
    requirements: [{ title: request.title, details: request.details ?? null, acceptance }],
    packages: [{ id: 'wp1', requirement: 0, title: clip(request.title, 60), profile: config.implementation.defaultProfile, requestedProfile: null,
      repo: request.repo ?? null, owns: [], after: [],
      purpose: clip(request.title, 600), completion: 'Every acceptance item listed in the brief is met and checked.',
      scope: 'Only what the requirement names. Stop and report in NEEDS_OWNER if it needs money, a contract, deletion, publishing or the owner\'s own operation.',
      verification: '', prompt: clipBytes([request.details || request.title, notes ? `\nStaff notes:\n${notes}` : ''].join(''), 6000) }],
    risks: [], ownerDecisions: [],
  };
}

// The bounded contract of one verification turn: evidence in, verdict JSON out.
export function verifyPrompt({ event, packet }) {
  const acceptance = (packet.acceptance ?? []).map((item) => `- ${item.id} [${item.status}]: ${item.text}${item.check ? ` — check: ${item.check}` : ''}`).join('\n');
  const subject = event.kind.startsWith('session.') ? [
    `SESSION: ${packet.session?.id ?? event.sessionId} "${clip(packet.title, 120)}" phase=${packet.session?.phase ?? packet.phase ?? '?'} origin=${event.origin ?? '?'}`,
    packet.requirement ? `REQUIREMENT: ${packet.requirement.id} ${clip(packet.requirement.title, 300)}` : 'REQUIREMENT: (none linked)',
    packet.package ? `PACKAGE: ${packet.package.id} — done condition: ${clip(packet.package.completion, 600)} — rework so far: ${packet.package.rework}` : null,
    acceptance ? `ACCEPTANCE\n${acceptance}` : null,
    `HAND-OFF SLIP (${packet.slipPresent ? `claims ${packet.claimedResult}` : 'missing'})`,
    ...Object.entries(packet.slip ?? {}).map(([key, value]) => `${key}: ${block(value)}`),
    packet.unavailable ? `LAST MESSAGE: unavailable (${packet.unavailable}) — read it with the session tools before deciding.` : `LAST MESSAGE (${packet.lastMessageChars} chars, tail):\n${block(packet.lastMessage)}`,
  ] : [
    `SUBJECT: ${clip(packet.title, 200)}`,
    `FACTS: ${JSON.stringify(Object.fromEntries(Object.entries(packet).filter(([key]) => !['title'].includes(key)))).slice(0, 2500)}`,
  ];
  return [
    `You are Monet verifying one inbox event (${event.id}, ${event.kind}). Decide from evidence, not from the session's claim.`,
    'Budget: at most 6 tool calls. Allowed: run an acceptance check, read one changed file or diff, read this session\'s conversation. Forbidden: laa-orchestrate mark, service control, anything outside this event\'s session or requirement, placing or changing orders.',
    '',
    ...subject.filter((line) => line !== null),
    '',
    'Answer by running exactly one command with a JSON file:',
    `  laa-bridge monet ack ${event.id} --verdict-file <path>`,
    'VERDICT JSON',
    '{"verdict": "verified | rework | needs_owner | not_mine | noted",',
    ' "acceptance": [{"id": "a1", "status": "passed | failed", "note": "一行・200字以内"}],',
    ' "note": "一行・200字以内・日本語（要件の確認メモになる）",',
    ' "followup": "rework の時だけ: セッションへ送る具体的な直し（English可）",',
    ' "decision": {"title": "…", "summary": "…", "options": ["…", "…"], "recommended": 0, "impact": "【任せられる】… or 【必ず社長：種類】…"},',
    ' "report": {"result": "…", "verification": "…", "residual": "…"}}',
    '- verified: every acceptance item is listed as passed and you checked CHANGED/VERIFIED against the real thing. "note" is required.',
    '- rework: something concrete is wrong or unchecked; "followup" is required. After the rework limit the Bridge raises a decision instead.',
    '- needs_owner: a choice that is not yours; "decision" is required.',
    '- not_mine / noted: nothing to verify (not a requirement of yours, or information only).',
  ].join('\n');
}
