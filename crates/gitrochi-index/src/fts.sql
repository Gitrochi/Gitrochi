-- Full-text tables over commits and paths. They read their text from the content
-- tables and need the `gitrochi` tokenizer (native/, C++), which the Rust index
-- registers on every connection. Readers without it must not query these tables.

CREATE VIRTUAL TABLE commit_text USING fts5 (
    subject, body, author_name, author_email,
    content = 'commits', content_rowid = 'id',
    tokenize = 'gitrochi', prefix = '2 3'
);

CREATE VIRTUAL TABLE path_text USING fts5 (
    path,
    content = 'paths', content_rowid = 'id',
    tokenize = 'gitrochi', prefix = '2 3'
);
