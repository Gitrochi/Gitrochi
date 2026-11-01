-- Ledger schema 1. Times are epoch milliseconds; JSON columns hold arrays or objects only.
-- Steps are additive: later schemas add tables and columns and never edit this step.

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT OR IGNORE INTO meta (key, value) VALUES ('rev', '0');

-- Global settings as JSON values (staleHours, kinds, autoContinue, backupKeep).
CREATE TABLE IF NOT EXISTS settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

-- A project is a trunk of baselines, keyed by the name agents report.
CREATE TABLE IF NOT EXISTS projects (
    key              TEXT PRIMARY KEY,
    name             TEXT NOT NULL,
    repo_path        TEXT,
    baseline_source  TEXT NOT NULL DEFAULT 'tags',  -- tags | folder | manual
    baseline_pattern TEXT,
    baseline_dir     TEXT,
    scan_files       INTEGER NOT NULL DEFAULT 0,
    scan_subdirs     TEXT NOT NULL DEFAULT '[]',
    created_at       INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS baselines (
    project    TEXT NOT NULL,
    version    TEXT NOT NULL,
    ts         INTEGER NOT NULL,
    source     TEXT NOT NULL,                       -- tag | folder | registered | release | inferred
    note       TEXT NOT NULL DEFAULT '',
    by_session TEXT,
    ref_name   TEXT,                                -- the tag, folder or file it came from
    commit_sha TEXT,
    PRIMARY KEY (project, version)
);

CREATE TABLE IF NOT EXISTS sessions (
    id              TEXT PRIMARY KEY,
    project         TEXT NOT NULL,
    kind            TEXT NOT NULL DEFAULT '',
    title           TEXT NOT NULL DEFAULT '',
    base_version    TEXT,                           -- the baseline it started from
    base_current    TEXT,                           -- the baseline it is on now (sync, release, applied)
    base_was_latest INTEGER NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'active',
    merged_into     TEXT,
    touches         TEXT NOT NULL DEFAULT '[]',
    related         TEXT NOT NULL DEFAULT '[]',
    chat_url        TEXT,
    links           TEXT NOT NULL DEFAULT '{}',
    channel         TEXT NOT NULL DEFAULT '',
    color           INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL,
    last_at         INTEGER NOT NULL,               -- last agent activity on the session
    last_agent_at   INTEGER,                        -- last report from its own agent
    ack_at          INTEGER,
    snooze_until    INTEGER,
    archived_at     INTEGER,
    auto_continue   TEXT                            -- JSON policy; NULL follows the global default
);
CREATE INDEX IF NOT EXISTS sessions_by_project ON sessions (project, created_at);

CREATE TABLE IF NOT EXISTS events (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   TEXT NOT NULL,
    project      TEXT NOT NULL,
    ts           INTEGER NOT NULL,
    type         TEXT NOT NULL,
    actor        TEXT NOT NULL,                     -- agent | human | auto | hook
    summary      TEXT NOT NULL DEFAULT '',
    body         TEXT,
    version      TEXT,
    artifacts    TEXT NOT NULL DEFAULT '[]',
    data         TEXT NOT NULL DEFAULT '{}',
    channel      TEXT NOT NULL DEFAULT '',
    delivered_at INTEGER                            -- when a person's message reached the agent
);
CREATE INDEX IF NOT EXISTS events_by_session ON events (session_id, ts, id);
CREATE INDEX IF NOT EXISTS events_by_project ON events (project, ts, id);

CREATE TABLE IF NOT EXISTS questions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id   TEXT NOT NULL,
    text         TEXT NOT NULL,
    state        TEXT NOT NULL DEFAULT 'open',      -- open | answered | dismissed
    answer       TEXT,
    answered_by  TEXT,                              -- human | auto | agent
    created_at   INTEGER NOT NULL,
    answered_at  INTEGER,
    delivered_at INTEGER,
    event_id     INTEGER
);
CREATE INDEX IF NOT EXISTS questions_by_session ON questions (session_id, state);

-- Hashes of pasted blocks already imported.
CREATE TABLE IF NOT EXISTS imports (
    hash TEXT PRIMARY KEY,
    ts   INTEGER NOT NULL
);

-- Prompts an agent is waiting on, for auto-continue.
CREATE TABLE IF NOT EXISTS pending_prompts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT,
    agent_id    TEXT,
    kind        TEXT NOT NULL,                      -- stop_question | ask_user_question | exit_plan_mode | permission
    payload     TEXT NOT NULL DEFAULT '{}',
    created_at  INTEGER NOT NULL,
    deadline    INTEGER NOT NULL,
    state       TEXT NOT NULL DEFAULT 'waiting',    -- waiting | answered | auto | released | expired
    answer      TEXT,
    answered_by TEXT,                               -- human | auto
    answered_at INTEGER,
    reviewed_at INTEGER                             -- a person looked at an automatic answer
);
CREATE INDEX IF NOT EXISTS pending_prompts_by_state ON pending_prompts (state, deadline);
