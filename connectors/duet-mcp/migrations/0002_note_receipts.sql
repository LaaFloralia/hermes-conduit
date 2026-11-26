-- Keep only the opaque IDs, not the text or timestamp, so retrying a note
-- stays idempotent even after the oldest note is evicted.
DROP INDEX note_receipts_created;
ALTER TABLE note_receipts DROP COLUMN created_ms;
