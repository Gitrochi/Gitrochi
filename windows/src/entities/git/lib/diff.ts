import { runCore } from "@/shared/core";
import { t } from "@/shared/i18n";
import type { DiffDocument, DiffFileInfo, DiffLine } from "../model/types";

export interface SplitRow { full?: number; left?: number; right?: number }
const rowsCache = new WeakMap<DiffLine[], SplitRow[]>();
const sidesCache = new WeakMap<DiffLine[], { old: boolean; new: boolean }>();

/** 파싱에서 계산한 배치를 재사용해 화면을 그릴 때마다 전체 diff를 다시 읽지 않는다. */
export function rememberDiff(lines: DiffLine[], rows: SplitRow[], sides: { old: boolean; new: boolean }) {
  rowsCache.set(lines, rows); sidesCache.set(lines, sides);
}
export const tokens = (text: string): string[] => runCore({ op: "tokens", text });
export const wordRanges = (a: string, b: string): [Array<[number, number]>, Array<[number, number]>] => runCore({ op: "wordRanges", a, b });
export function markWords(lines: DiffLine[]) {
  const marked = runCore<DiffLine[]>({ op: "markWords", lines });
  marked.forEach((line, i) => { lines[i].changes = line.changes ?? []; });
}
export function diffSides(lines: DiffLine[]): { old: boolean; new: boolean } {
  const cached = sidesCache.get(lines);
  if (cached) return cached;
  const sides = { old: lines.some((l) => l.oldNo !== null), new: lines.some((l) => l.newNo !== null) };
  sidesCache.set(lines, sides); return sides;
}
export function splitRows(lines: DiffLine[]): SplitRow[] {
  const cached = rowsCache.get(lines);
  if (cached) return cached;
  const rows = runCore<SplitRow[]>({ op: "splitRows", lines });
  rowsCache.set(lines, rows); return rows;
}
export const canEditLines = (doc: DiffDocument): boolean => runCore({ op: "canEdit", doc: { header: doc.header, hunks: doc.hunks, isBinary: doc.isBinary, combined: doc.combined, multipleFiles: doc.multipleFiles, truncated: doc.truncated } });
export const buildPatch = (doc: DiffDocument, hunks: number[], selected: Set<number> | null, reverse: boolean): string | null =>
  runCore({ op: "patch", doc, hunks, selected: selected ? [...selected] : null, reverse });

/** 권한 바뀜 설명(실행 권한이 생기거나 없어졌을 때) */
export function modeSummary(info: DiffFileInfo | undefined): string | null {
  if (!info || info.newFile || info.deletedFile || !info.oldMode || !info.newMode || info.oldMode === info.newMode) return null;
  const was = info.oldMode.endsWith("755"),
    now = info.newMode.endsWith("755");
  const note = !was && now ? t(" — now executable") : was && !now ? t(" — no longer executable") : "";
  return `${info.oldMode} → ${info.newMode}${note}`;
}
