-- Browser observations keep source provenance separate from agent recommendations and delivery.
ALTER TABLE questions ADD COLUMN browser_source_url TEXT;
ALTER TABLE questions ADD COLUMN browser_draft TEXT;
CREATE TABLE IF NOT EXISTS browser_captures (
    origin TEXT NOT NULL,
    conversation TEXT NOT NULL,
    session_id TEXT NOT NULL,
    source_key TEXT NOT NULL,
    digest TEXT NOT NULL,
    question_id INTEGER NOT NULL UNIQUE,
    PRIMARY KEY (origin, conversation, session_id, source_key)
);
