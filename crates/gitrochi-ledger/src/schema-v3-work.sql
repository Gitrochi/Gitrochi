-- Work records are separate from session state and retain their own dated history.
CREATE TABLE IF NOT EXISTS ledger_work_bundles (
    project TEXT NOT NULL,
    name TEXT NOT NULL,
    created_date TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (project, name)
);
CREATE TABLE IF NOT EXISTS ledger_work_items (
    id TEXT PRIMARY KEY,
    project TEXT NOT NULL,
    bundle TEXT NOT NULL,
    title TEXT NOT NULL,
    output TEXT NOT NULL DEFAULT '',
    scope TEXT NOT NULL DEFAULT '[]',
    stem TEXT NOT NULL DEFAULT '',
    from_item TEXT,
    created_date TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ledger_work_items_project ON ledger_work_items(project, bundle);
CREATE TABLE IF NOT EXISTS ledger_work_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project TEXT NOT NULL,
    item TEXT,
    bundle TEXT,
    kind TEXT NOT NULL,
    date TEXT NOT NULL,
    estimated INTEGER NOT NULL DEFAULT 0,
    text TEXT NOT NULL DEFAULT '',
    refs TEXT NOT NULL DEFAULT '[]',
    plan TEXT,
    data TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ledger_work_events_item ON ledger_work_events(item, date, id);
CREATE INDEX IF NOT EXISTS ledger_work_events_project ON ledger_work_events(project, date, id);
CREATE TABLE IF NOT EXISTS ledger_work_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project TEXT NOT NULL,
    item TEXT,
    event_id INTEGER,
    action TEXT NOT NULL,
    date TEXT NOT NULL,
    before_value TEXT NOT NULL,
    after_value TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ledger_work_marks (
    project TEXT NOT NULL,
    event_id INTEGER NOT NULL,
    date TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(project, event_id)
);
CREATE TABLE IF NOT EXISTS ledger_work_notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project TEXT NOT NULL,
    target TEXT NOT NULL DEFAULT '',
    text TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    delivered_at INTEGER
);
CREATE TABLE IF NOT EXISTS ledger_work_imports (
    hash TEXT PRIMARY KEY,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS ledger_work_links (
    project TEXT NOT NULL,
    item TEXT NOT NULL,
    event_id INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(project, item, event_id)
);
CREATE TABLE IF NOT EXISTS ledger_work_legacy_keys (
    source TEXT NOT NULL,
    kind TEXT NOT NULL,
    original TEXT NOT NULL,
    target TEXT NOT NULL,
    PRIMARY KEY(source, kind, original)
);
