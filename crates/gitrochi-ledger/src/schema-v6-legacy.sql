-- Imported source rows are retained separately so corrections and original references remain auditable.
CREATE TABLE IF NOT EXISTS ledger_legacy_rows (
    source TEXT NOT NULL,
    table_name TEXT NOT NULL,
    row_key TEXT NOT NULL,
    body TEXT NOT NULL,
    PRIMARY KEY (source, table_name, row_key)
);
CREATE TABLE IF NOT EXISTS ledger_legacy_event_ids (
    source TEXT NOT NULL,
    legacy_id INTEGER NOT NULL,
    event_id INTEGER NOT NULL,
    PRIMARY KEY (source, legacy_id)
);
CREATE TABLE IF NOT EXISTS ledger_legacy_notes (
    source TEXT NOT NULL,
    legacy_id TEXT NOT NULL,
    note_id INTEGER NOT NULL,
    PRIMARY KEY (source, legacy_id)
);
