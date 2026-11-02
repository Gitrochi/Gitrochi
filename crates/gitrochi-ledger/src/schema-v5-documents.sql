-- Document sources are selected by a person; only derived evidence is cached.
CREATE TABLE IF NOT EXISTS document_roots (
    project TEXT NOT NULL,
    path TEXT NOT NULL,
    PRIMARY KEY (project, path)
);
CREATE TABLE IF NOT EXISTS document_files (
    project TEXT NOT NULL,
    root TEXT NOT NULL,
    path TEXT NOT NULL,
    hash TEXT NOT NULL,
    held_hash TEXT,
    modified_at INTEGER NOT NULL,
    scanned_at INTEGER NOT NULL,
    entries TEXT NOT NULL DEFAULT '[]',
    PRIMARY KEY (project, root, path)
);
