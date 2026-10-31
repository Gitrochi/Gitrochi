import type { LedgerImportResult } from "../model/types";

export type ImportOutcome = "imported" | "duplicate" | "failed";

export interface ImportLine {
  /** 1-based, as a person counts the pasted reports */
  number: number;
  outcome: ImportOutcome;
  sessionId?: string;
  error?: string;
}

export interface ImportSummary {
  lines: ImportLine[];
  imported: number;
  duplicates: number;
  failed: number;
  /** Sessions the import touched, in first-seen order, to open from the sheet */
  sessions: string[];
}

/**
 * One line per pasted report, in the order they were pasted: imported, already imported (duplicate) or failed with
 * the backend's reason. One bad report never hides the others. (macOS: LedgerImport.summary)
 */
export function summarizeImport(results: readonly LedgerImportResult[]): ImportSummary {
  const lines = [...results]
    .sort((a, b) => a.index - b.index)
    .map((r): ImportLine => ({
      number: r.index + 1,
      outcome: r.duplicate ? "duplicate" : r.ok ? "imported" : "failed",
      ...(r.sessionId ? { sessionId: r.sessionId } : {}),
      ...(!r.ok && !r.duplicate ? { error: r.error?.trim() || "Unknown error" } : {}),
    }));
  const sessions: string[] = [];
  for (const l of lines) if (l.sessionId && l.outcome !== "failed" && !sessions.includes(l.sessionId)) sessions.push(l.sessionId);
  return {
    lines,
    imported: lines.filter((l) => l.outcome === "imported").length,
    duplicates: lines.filter((l) => l.outcome === "duplicate").length,
    failed: lines.filter((l) => l.outcome === "failed").length,
    sessions,
  };
}

/**
 * How many reports a paste holds, before importing: fenced ```ledger blocks, else one JSON object per line that has an
 * "event", else the whole text as one report. The backend parses for real; this only labels the Import button.
 */
export function countReports(text: string): number {
  const fenced = text.match(/```ledger[^\n]*\n[\s\S]*?```/g);
  if (fenced) return fenced.length;
  const lines = text.split(/\r?\n/).filter((line) => /^\s*\{/.test(line) && /"event"\s*:/.test(line));
  if (lines.length) return lines.length;
  return text.trim() ? 1 : 0;
}
