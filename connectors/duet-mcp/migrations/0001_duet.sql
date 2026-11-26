CREATE TABLE items (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('brief', 'update', 'done', 'needs_owner')),
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  link TEXT,
  created_ms INTEGER NOT NULL
);
CREATE INDEX items_created ON items(created_ms);

CREATE TABLE notes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT UNIQUE NOT NULL,
  text TEXT NOT NULL,
  created_ms INTEGER NOT NULL,
  read INTEGER NOT NULL DEFAULT 0 CHECK (read IN (0, 1))
);
CREATE INDEX notes_unread ON notes(read, seq);

-- Remember expired note IDs without retaining their contents, to make a retry
-- after a lost response safe even when the note row has already been evicted.
CREATE TABLE note_receipts (id TEXT PRIMARY KEY, created_ms INTEGER NOT NULL);
CREATE INDEX note_receipts_created ON note_receipts(created_ms);

CREATE TABLE rate_limit (
  target TEXT NOT NULL,
  at_ms INTEGER NOT NULL
);
CREATE INDEX rate_limit_target_window ON rate_limit(target, at_ms);
CREATE INDEX rate_limit_window ON rate_limit(at_ms);
