-- Structured questions preserve choices and editable suggestions across client reports.
ALTER TABLE questions ADD COLUMN metadata TEXT NOT NULL DEFAULT '{}';
