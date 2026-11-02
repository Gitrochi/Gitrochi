-- Cached AI text is bound to approved source hashes, never to provider credentials.
CREATE TABLE IF NOT EXISTS document_summaries (
    project TEXT NOT NULL,
    source_key TEXT NOT NULL,
    identity TEXT NOT NULL,
    text TEXT NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    requested_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    request_id TEXT NOT NULL,
    request_chars INTEGER NOT NULL,
    response_chars INTEGER NOT NULL,
    PRIMARY KEY (project, source_key)
);
CREATE TABLE IF NOT EXISTS document_summary_usage (
    project TEXT NOT NULL,
    month TEXT NOT NULL,
    requests INTEGER NOT NULL DEFAULT 0,
    request_chars INTEGER NOT NULL DEFAULT 0,
    response_chars INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (project, month)
);
