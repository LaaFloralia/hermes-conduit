// Shared presentation for the CLI and (via `brief`) the personal agent's
// prompt. The ref is always quoted together with the title so a number that
// was reused after the cooldown cannot be mistaken for the old object.

export const KIND_LABEL = Object.freeze({
  task: 'タスク',
  session: 'セッション',
  project: 'プロジェクト',
  routine: '定期実行',
  skill: 'スキル',
  decision: '判断',
});

function externalLine(kind, external = {}) {
  if (kind === 'task') {
    const linear = external.linear ?? '';
    return `Linear ${linear}${external.url ? ` ${external.url}` : ''}`.trim();
  }
  if (kind === 'session') return `Paseo ${external.paseoAgentId ?? ''}`.trim();
  if (kind === 'skill' && Array.isArray(external.sources) && external.sources.length > 0) {
    return external.sources.join('/');
  }
  return '';
}

export function formatRefLine(record) {
  if (!record) return '';
  const label = KIND_LABEL[record.kind] ?? record.kind;
  const external = externalLine(record.kind, record.external);
  return `${record.ref} ${label}「${record.title}」${external ? ` ${external}` : ''}`;
}

export function formatResultLine(result) {
  if (result.status === 'active' && result.holder) return formatRefLine(result.holder);
  if (result.status === 'released') {
    const previous = result.previous[0];
    const at = previous?.releasedAt ?? '';
    const who = previous ? `最後の持ち主: ${formatRefLine({ ...previous, ref: '' }).trim()}` : '';
    return `${result.ref} は解放済み（${at}）。${who}`;
  }
  return `${result.ref} は未使用です。`;
}

// One Japanese line the personal agent pastes into a new session's prompt,
// after the owner says "S5やって".
export function briefFor(result) {
  if (result.status !== 'active' || !result.holder) return null;
  const record = result.holder;
  const title = record.title;
  if (record.kind === 'task') {
    const linear = record.external?.linear ?? '';
    const url = record.external?.url ? ` ${record.external.url}` : '';
    return `${record.ref}＝社長のタスク「${title}」（Linear ${linear}${url}）。最初にLinearで本文とコメントを読んでから進める。`;
  }
  if (record.kind === 'session') {
    return `${record.ref}＝Workのセッション「${title}」（Paseo ${record.external?.paseoAgentId ?? ''}）。`;
  }
  if (record.kind === 'decision') {
    return `${record.ref}＝判断ボードの判断「${title}」（laa-bridge decide status ${record.key}）。`;
  }
  return `${record.ref}＝${KIND_LABEL[record.kind] ?? record.kind}「${title}」。`;
}
