-- db.rs adds browser question columns conditionally to preserve populated preview databases.
CREATE TABLE IF NOT EXISTS browser_captures (
    origin TEXT NOT NULL,
    conversation TEXT NOT NULL,
    session_id TEXT NOT NULL,
    source_key TEXT NOT NULL,
    digest TEXT NOT NULL,
    question_id INTEGER NOT NULL UNIQUE,
    PRIMARY KEY (origin, conversation, session_id, source_key)
);

-- A durable generation distinguishes replacement sessions even when their IDs and times match.
CREATE TABLE IF NOT EXISTS browser_session_generations (
    generation INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL UNIQUE
);
INSERT OR IGNORE INTO browser_session_generations (session_id)
SELECT id FROM sessions ORDER BY id;

-- REPLACE can skip SQLite's delete triggers, so an insert always retires the old identity.
CREATE TRIGGER IF NOT EXISTS browser_session_insert AFTER INSERT ON sessions
BEGIN
    DELETE FROM browser_captures WHERE session_id = NEW.id;
    DELETE FROM browser_session_generations WHERE session_id = NEW.id;
    INSERT INTO browser_session_generations (session_id) VALUES (NEW.id);
END;

CREATE TRIGGER IF NOT EXISTS browser_session_delete AFTER DELETE ON sessions
BEGIN
    DELETE FROM browser_captures WHERE session_id = OLD.id;
    DELETE FROM browser_session_generations WHERE session_id = OLD.id;
END;
