-- Personal notes stay outside the agent-facing session and work records.
CREATE TABLE IF NOT EXISTS notebook_notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    pinned INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS notebook_notes_by_update ON notebook_notes (pinned, updated_at);
