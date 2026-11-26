const DAYS_30 = 30 * 86400_000;
const fields = 'seq, kind, title, body, link, created_ms';
const itemJson = ({ seq, kind, title, body, link, created_ms }) => ({
  id: String(seq), kind, title, body, link, createdAt: new Date(created_ms).toISOString(),
});

export async function takeRate(db, target, limit, now = Date.now()) {
  // An INSERT with an atomic predicate avoids the check-then-increment race.
  const result = await db.prepare(`INSERT INTO rate_limit(target, at_ms)
    SELECT ?, ? WHERE (SELECT COUNT(*) FROM rate_limit WHERE target = ? AND at_ms > ?) < ?`)
    .bind(target, now, target, now - 60_000, limit).run();
  return result.meta.changes === 1;
}

export async function postItem(db, item, now = Date.now()) {
  const [insert] = await db.batch([
    db.prepare(`INSERT INTO items(kind, title, body, link, created_ms) VALUES (?, ?, ?, ?, ?) RETURNING seq`)
      .bind(item.kind, item.title, item.body, item.link, now),
    db.prepare('DELETE FROM items WHERE created_ms <= ?').bind(now - DAYS_30),
    db.prepare('DELETE FROM items WHERE seq IN (SELECT seq FROM items ORDER BY seq DESC LIMIT -1 OFFSET 500)'),
  ]);
  return { id: String(insert.results[0].seq) };
}

export async function pullItems(db, after, now = Date.now()) {
  const { results } = await db.prepare(`SELECT ${fields} FROM items WHERE seq > ? AND created_ms > ? ORDER BY seq LIMIT 50`)
    .bind(after, now - DAYS_30).all();
  return { items: results.map(itemJson) };
}

export async function ackItems(db, through) {
  const [check] = await db.batch([
    db.prepare("SELECT 1 AS ok FROM sqlite_sequence WHERE name = 'items' AND seq >= ?").bind(through),
    db.prepare("DELETE FROM items WHERE seq <= ? AND EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'items' AND seq >= ?)")
      .bind(through, through),
  ]);
  return check.results.length === 1;
}

export async function putNote(db, id, text, now = Date.now()) {
  await db.batch([
    db.prepare('INSERT INTO notes(id, text, created_ms) SELECT ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM note_receipts WHERE id = ?) ON CONFLICT(id) DO NOTHING')
      .bind(id, text, now, id),
    db.prepare('INSERT OR IGNORE INTO note_receipts(id) VALUES (?)').bind(id),
    db.prepare('DELETE FROM notes WHERE seq IN (SELECT seq FROM notes ORDER BY seq DESC LIMIT -1 OFFSET 200)'),
  ]);
  return { id };
}

export async function readNotes(db) {
  // Selection and marking are one write, so simultaneous calls cannot both
  // take the same unread notes. RETURNING does not promise an output order.
  const { results } = await db.prepare(`UPDATE notes SET read = 1 WHERE seq IN
    (SELECT seq FROM notes WHERE read = 0 ORDER BY seq LIMIT 20) RETURNING seq, id, text, created_ms`).all();
  return { notes: results.sort((a, b) => a.seq - b.seq).map(({ id, text, created_ms }) => ({
    id, text, createdAt: new Date(created_ms).toISOString(),
  })) };
}

export async function noteStatus(db) {
  const { results } = await db.prepare('SELECT id FROM notes WHERE read = 1 ORDER BY seq').all();
  return { read: results.map(({ id }) => id) };
}

export async function prune(db, now = Date.now()) {
  await db.batch([
    db.prepare('DELETE FROM items WHERE created_ms <= ?').bind(now - DAYS_30),
    db.prepare('DELETE FROM rate_limit WHERE at_ms <= ?').bind(now - 60_000),
  ]);
}
