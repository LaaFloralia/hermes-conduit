"""Report-only Bot Chat writes for Hermes builds without session_cron.

Use Hermes' transaction, turn-lease fence and message serializer. Never
invoke a gateway turn or spawn a chat process.
"""
from __future__ import annotations

import inspect
from pathlib import Path
from typing import Any


def supported() -> bool:
    try:
        from hermes_state import SessionDB
        methods = ("_execute_write", "_compression_tip_on", "_check_transcript_write_guards",
                   "_insert_message_rows", "_bump_session_counters", "_decode_content",
                   "get_session_by_title", "get_compression_tip")
        return (all(callable(getattr(SessionDB, name, None)) for name in methods)
                and "reject_active_turn_lease" in inspect.signature(
                    SessionDB._check_transcript_write_guards).parameters)
    except (ImportError, AttributeError, TypeError, ValueError):
        return False


def bot_chat_tip(home: Path) -> str | None:
    from hermes_state import SessionDB
    if not (home / "state.db").is_file():
        return None
    db = SessionDB(db_path=home / "state.db", read_only=True)
    try:
        row = db.get_session_by_title("Bot Chat")
        return db.get_compression_tip(row["id"]) if row else None
    finally:
        db.close()


def write_note(db: Any, session_id: str, key: str, text: str, metadata: dict) -> int:
    """Use Hermes' native writer when present, otherwise its guarded state adapter."""
    append = getattr(db, "append_completion_note", None)
    if callable(append):
        return append(session_id, key, text, "internal_notification", metadata)
    return _write_legacy(db, session_id, key, text, metadata)


def write_staff_note(home: Path, session_id: str, key: str, text: str, metadata: dict) -> str:
    """Preserve existing staff-note IDs and content on retry, even after compression."""
    if not supported():
        raise ValueError("Report-only storage unavailable; no AI turn")
    from hermes_state import SessionDB

    db = SessionDB(db_path=home / 'state.db')
    try:
        _write_legacy(db, session_id, key, text, metadata, routine=True)
        return db.get_compression_tip(session_id)
    finally:
        db.close()


def _write_legacy(db: Any, session_id: str, key: str, text: str, metadata: dict, *, routine=False) -> int:
    if not supported():
        raise ValueError("Report-only storage unavailable; no AI turn")
    return append_note(db, session_id, key, text, metadata, routine=routine)


def append_note(db: Any, session_id: str, key: str, text: str, metadata: dict, *, routine=False) -> int:
    """Idempotent across compression and concurrent processes in one transaction."""
    if not key:
        raise ValueError("A stable cron execution key is required")

    def write(conn):
        # Resolve again under the writer lock: rotation cannot race the insert.
        tip = db._compression_tip_on(conn, session_id)
        if conn.execute("SELECT 1 FROM sessions WHERE id = ?", (tip,)).fetchone() is None:
            raise ValueError("Bot Chat no longer exists")
        # Include inactive rows and compression ancestors: a compacted note
        # must not be presented again. Like append_delegation_delivery.
        row = conn.execute(
            """WITH RECURSIVE lineage(id) AS (
                SELECT ? UNION
                SELECT s.parent_session_id FROM sessions s JOIN lineage l ON s.id = l.id
                JOIN sessions p ON p.id = s.parent_session_id WHERE p.end_reason = 'compression'
            ) SELECT m.id, m.content FROM messages m JOIN lineage l ON m.session_id = l.id
            WHERE m.display_kind = 'internal_notification' AND (
                json_extract(m.display_metadata, '$.conduit_cron_delivery_id') = ?
                OR (? AND m.platform_message_id = ?)
            ) LIMIT 1""", (tip, key, routine, key)).fetchone()
        if row is not None:
            # A staff repeat/recovery notice has composed text on its first
            # delivery. A retry must keep that note, not replace it with raw output.
            if not routine and db._decode_content(row[1]) != text:
                raise ValueError("Cron delivery id already belongs to a different payload")
            return int(row[0])
        db._check_transcript_write_guards(conn, tip, None, reject_active_turn_lease=True)
        message = {"role": "user", "content": text, "display_kind": "internal_notification",
                   "display_metadata": {**metadata, "conduit_cron_delivery_id": key}}
        inserted, calls = db._insert_message_rows(conn, tip, [message])
        db._bump_session_counters(conn, tip, inserted, calls, unit=True)
        return int(message["_row_id"])

    # The caller owns the overall wait budget; no AI fallback on contention.
    return db._execute_write(write, patience_s=1.0)
