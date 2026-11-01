-- A database in the standalone claude-ledger tool's shape, for Import from claude-ledger… (test-ledger.sh and
-- test-ledger-layout.sh): only the columns the import needs, two sessions (one of a kind with no role yet), their
-- start events, an open question and a version. Made up for the tests: sqlite3 <file> < claude-ledger.sql
CREATE TABLE sessions (id TEXT, project TEXT, kind TEXT, title TEXT, status TEXT, created_ts INTEGER, last_ts INTEGER);
CREATE TABLE events (session_id TEXT, ts INTEGER, type TEXT, actor TEXT, summary TEXT);
CREATE TABLE items (id INTEGER, session_id TEXT, text TEXT);
CREATE TABLE versions (project TEXT, version TEXT, ts INTEGER);
INSERT INTO sessions VALUES ('legacy-one', 'Legacy Tool', 'spike', 'Imported work', 'active', 1793000000000, 1793000100000);
INSERT INTO sessions VALUES ('legacy-two', 'Legacy Tool', 'research', 'Older research', 'closed', 1792000000000, 1792000100000);
INSERT INTO events VALUES ('legacy-one', 1793000000000, 'start', 'claude', 'Started');
INSERT INTO events VALUES ('legacy-two', 1792000000000, 'start', 'claude', 'Started');
INSERT INTO items VALUES (1, 'legacy-one', 'Keep the old flag?');
INSERT INTO versions VALUES ('Legacy Tool', '0.9', 1791000000000);
