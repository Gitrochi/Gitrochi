-- Gitrochi repository index, schema 1 (PRAGMA user_version = 1).
-- crates/gitrochi-index is the only writer. Python, Go and the apps may read these
-- tables (open read-only and check user_version first). The full-text tables in
-- fts.sql need the C++ `gitrochi` tokenizer and are created separately.

CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

-- One row per indexed commit. Times are Unix seconds; author fields follow .mailmap.
-- seq orders commits that share a commit time the way git listed them (children first);
-- readers sort by (commit_time DESC, seq DESC).
CREATE TABLE commits (
    id              INTEGER PRIMARY KEY,
    sha             TEXT    NOT NULL UNIQUE,
    tree            TEXT    NOT NULL,
    author_name     TEXT    NOT NULL,
    author_email    TEXT    NOT NULL,
    author_time     INTEGER NOT NULL,
    committer_name  TEXT    NOT NULL,
    committer_email TEXT    NOT NULL,
    commit_time     INTEGER NOT NULL,
    subject         TEXT    NOT NULL,
    body            TEXT    NOT NULL,
    parent_count    INTEGER NOT NULL,
    files_changed   INTEGER NOT NULL,
    additions       INTEGER NOT NULL,
    deletions       INTEGER NOT NULL,
    seq             INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX commits_time ON commits (commit_time DESC, seq DESC);
CREATE INDEX commits_author ON commits (author_email, commit_time DESC);

CREATE TABLE commit_parents (
    commit_id  INTEGER NOT NULL REFERENCES commits (id) ON DELETE CASCADE,
    position   INTEGER NOT NULL,
    parent_sha TEXT    NOT NULL,
    PRIMARY KEY (commit_id, position)
) WITHOUT ROWID;
CREATE INDEX commit_parents_sha ON commit_parents (parent_sha);

-- Repository-relative paths with '/' separators, interned once.
CREATE TABLE paths (
    id   INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE
);

-- Files changed by non-merge commits (merges have no diff in `git log`).
-- status is git's letter: A, M, D, R, C or T. Line counts are NULL for binary files.
CREATE TABLE file_changes (
    commit_id   INTEGER NOT NULL REFERENCES commits (id) ON DELETE CASCADE,
    path_id     INTEGER NOT NULL REFERENCES paths (id),
    status      TEXT    NOT NULL,
    old_path_id INTEGER REFERENCES paths (id),
    similarity  INTEGER,
    additions   INTEGER,
    deletions   INTEGER,
    PRIMARY KEY (commit_id, path_id)
) WITHOUT ROWID;
CREATE INDEX file_changes_path ON file_changes (path_id, commit_id);

-- Per-path totals, kept in step with file_changes. coupling_commits counts only the
-- commits small enough for cochange, so it is the denominator of a pair's confidence.
CREATE TABLE path_stats (
    path_id          INTEGER PRIMARY KEY REFERENCES paths (id),
    commits          INTEGER NOT NULL,
    coupling_commits INTEGER NOT NULL,
    additions        INTEGER NOT NULL,
    deletions        INTEGER NOT NULL,
    first_time       INTEGER NOT NULL,
    last_time        INTEGER NOT NULL
);

-- Change relationships: how often two paths changed in the same commit (a < b).
-- Commits touching more than meta.max_files paths are left out as noise.
CREATE TABLE cochange (
    a         INTEGER NOT NULL REFERENCES paths (id),
    b         INTEGER NOT NULL REFERENCES paths (id),
    commits   INTEGER NOT NULL,
    last_time INTEGER NOT NULL,
    PRIMARY KEY (a, b),
    CHECK (a < b)
) WITHOUT ROWID;
CREATE INDEX cochange_b ON cochange (b, a);

-- Ref tips whose full ancestry is indexed; the next sync walks only past them.
CREATE TABLE refs (
    name TEXT PRIMARY KEY,
    sha  TEXT NOT NULL
) WITHOUT ROWID;

-- Results of searches that need git (pickaxe, grep), keyed by query and options.
-- scope names what the result belongs to: a tree SHA or a fingerprint of the ref tips.
CREATE TABLE search_cache (
    key     TEXT    PRIMARY KEY,
    kind    TEXT    NOT NULL,
    query   TEXT    NOT NULL,
    scope   TEXT    NOT NULL,
    created INTEGER NOT NULL,
    used    INTEGER NOT NULL,
    hits    INTEGER NOT NULL,
    bytes   INTEGER NOT NULL,
    result  TEXT    NOT NULL
) WITHOUT ROWID;
CREATE INDEX search_cache_used ON search_cache (used);
