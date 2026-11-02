export interface DocumentSummaryEvidence {
  root: string;
  path: string;
  line: number;
  text: string;
  hash: string;
}

/** Preserve complete source references while limiting what an explicit AI request sends. */
export function documentSummaryContext(evidence: readonly DocumentSummaryEvidence[], limit = 12000): string {
  const rows: { path: string; line: number; text: string }[] = [];
  for (const entry of evidence) {
    const row = { path: entry.path, line: entry.line, text: entry.text };
    if (JSON.stringify([...rows, row]).length > limit) break;
    rows.push(row);
  }
  return JSON.stringify(rows);
}

/** Content hashes invalidate summaries while provider settings and keys stay out of the cache. */
export function documentSummaryKey(project: string, id: string, evidence: readonly DocumentSummaryEvidence[]): string {
  return JSON.stringify([project, id, [...new Set(evidence.map((row) => `${row.root}/${row.path}:${row.hash}`))].sort()]);
}
