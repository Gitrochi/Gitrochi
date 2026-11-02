-- The unreleased browser preview used schema 3 before the production work migration merged.
ALTER TABLE questions ADD COLUMN browser_source_url TEXT;
ALTER TABLE questions ADD COLUMN browser_draft TEXT;
CREATE TABLE browser_captures (
    origin TEXT NOT NULL,
    conversation TEXT NOT NULL,
    session_id TEXT NOT NULL,
    source_key TEXT NOT NULL,
    digest TEXT NOT NULL,
    question_id INTEGER NOT NULL UNIQUE,
    PRIMARY KEY (origin, conversation, session_id, source_key)
);
PRAGMA user_version = 3;
