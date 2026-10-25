import { t } from "@/shared/i18n";
import type { DiffDocument, DiffFileInfo, DiffLine } from "../model/types";

/** 단어 단위 diff · 나란히 보기 · 줄 단위 스테이지 패치 (맥 버전 Core/DiffTools.swift 와 같은 규칙) */

// MARK: - 단어 단위

/** 한 줄에서 바뀐 부분이 이보다 많으면(거의 다 바뀜) 표시하지 않는다 */
const MAX_CHANGED_RATIO = 0.7;
const MAX_TOKENS = 400;

/** 글자·숫자 묶음, 공백 묶음, 그 밖의 글자 하나씩 */
export function tokens(s: string): string[] {
  const out: string[] = [];
  const kind = (c: string) => (/[\p{L}\p{N}_]/u.test(c) ? 0 : /\s/.test(c) ? 1 : 2);
  let cur = "",
    k = -1;
  for (const c of s) {
    const ck = kind(c);
    if (cur && (ck !== k || ck === 2)) {
      out.push(cur);
      cur = "";
    }
    cur += c;
    k = ck;
  }
  if (cur) out.push(cur);
  return out;
}

/** 두 줄에서 바뀐 글자 위치([시작, 끝) — 글자 수 기준) */
export function wordRanges(a: string, b: string): [Array<[number, number]>, Array<[number, number]>] {
  const ta = tokens(a),
    tb = tokens(b);
  if (!ta.length || !tb.length || ta.length > MAX_TOKENS || tb.length > MAX_TOKENS) return [[], []];
  const dp: number[][] = Array.from({ length: ta.length + 1 }, () => new Array(tb.length + 1).fill(0));
  for (let x = ta.length - 1; x >= 0; x--) for (let y = tb.length - 1; y >= 0; y--) dp[x][y] = ta[x] === tb[y] ? dp[x + 1][y + 1] + 1 : Math.max(dp[x + 1][y], dp[x][y + 1]);
  const keepA = new Array(ta.length).fill(false),
    keepB = new Array(tb.length).fill(false);
  let x = 0,
    y = 0;
  while (x < ta.length && y < tb.length) {
    if (ta[x] === tb[y]) {
      keepA[x++] = true;
      keepB[y++] = true;
    } else if (dp[x + 1][y] >= dp[x][y + 1]) x++;
    else y++;
  }
  const spans = (text: string[], keep: boolean[]) => {
    const out: Array<[number, number]> = [];
    let pos = 0,
      changed = 0,
      total = 0;
    text.forEach((tok, n) => {
      const len = [...tok].length;
      const blank = !tok.trim();
      if (!keep[n]) {
        if (!blank) changed += len;
        const last = out[out.length - 1];
        if (last && last[1] === pos) last[1] = pos + len;
        else out.push([pos, pos + len]);
      }
      if (!blank) total += len;
      pos += len;
    });
    return { out, changed, total };
  };
  const sa = spans(ta, keepA),
    sb = spans(tb, keepB);
  if ((sa.changed + sb.changed) / Math.max(1, sa.total + sb.total) > MAX_CHANGED_RATIO) return [[], []];
  return [sa.out, sb.out];
}

/** 지워진 줄 묶음과 바로 뒤 더해진 줄 묶음을 순서대로 짝지어 바뀐 부분을 채운다 */
export function markWords(lines: DiffLine[]) {
  let i = 0;
  while (i < lines.length) {
    if (lines[i].kind !== "removed") {
      i++;
      continue;
    }
    let r = i;
    while (r < lines.length && lines[r].kind === "removed") r++;
    let a = r;
    while (a < lines.length && lines[a].kind === "added") a++;
    for (let k = 0; k < Math.min(r - i, a - r); k++) {
      const [o, n] = wordRanges(lines[i + k].text, lines[r + k].text);
      lines[i + k].changes = o;
      lines[r + k].changes = n;
    }
    i = Math.max(a, i + 1);
  }
}

// MARK: - 나란히 보기

/** 이전·이후 줄 번호가 하나라도 있는지(새 파일은 이전 칸, 지운 파일은 이후 칸이 없다). 한쪽만 있으면 나란히 봐도 한 칸으로. */
export function diffSides(lines: DiffLine[]): { old: boolean; new: boolean } {
  return { old: lines.some((l) => l.oldNo !== null), new: lines.some((l) => l.newNo !== null) };
}

/** 권한 바뀜 설명(실행 권한이 생기거나 없어졌을 때) */
export function modeSummary(info: DiffFileInfo | undefined): string | null {
  if (!info || info.newFile || info.deletedFile || !info.oldMode || !info.newMode || info.oldMode === info.newMode) return null;
  const was = info.oldMode.endsWith("755"),
    now = info.newMode.endsWith("755");
  const note = !was && now ? t(" — now executable") : was && !now ? t(" — no longer executable") : "";
  return `${info.oldMode} → ${info.newMode}${note}`;
}

/** 나란히 보기 한 줄: @@·"줄바꿈 없음" 줄은 가로 전체(full), 그 밖에는 왼쪽(지운 줄·문맥)과 오른쪽(더한 줄·문맥). 값은 lines 의 위치. */
export interface SplitRow {
  full?: number;
  left?: number;
  right?: number;
}

export function splitRows(lines: DiffLine[]): SplitRow[] {
  const rows: SplitRow[] = [];
  let i = 0;
  while (i < lines.length) {
    const k = lines[i].kind;
    if (k === "hunk" || k === "meta") rows.push({ full: i++ });
    else if (k === "context") {
      rows.push({ left: i, right: i });
      i++;
    } else {
      const removed: number[] = [],
        added: number[] = [];
      while (i < lines.length && lines[i].kind === "removed") removed.push(i++);
      while (i < lines.length && lines[i].kind === "added") added.push(i++);
      for (let n = 0; n < Math.max(removed.length, added.length); n++) rows.push({ left: removed[n], right: added[n] });
    }
  }
  return rows;
}

// MARK: - 줄 단위 스테이지

/** 이 diff 로 줄 단위 패치를 만들 수 있는지(새 파일·지운 파일·이름 바꾼 파일·결합 diff·바이너리는 파일째로만) */
export function canEditLines(doc: DiffDocument): boolean {
  if (doc.isBinary || doc.combined || doc.multipleFiles || !doc.hunks.length || doc.truncated) return false;
  const h = doc.header;
  if (!h.some((l) => /^--- "?a\//.test(l)) || !h.some((l) => /^\+\+\+ "?b\//.test(l))) return false;
  return !h.some((l) => l.startsWith("new file mode") || l.startsWith("deleted file mode") || l.startsWith("rename ") || l.startsWith("similarity"));
}

/**
 * 고른 줄만 담은 패치(git add -p 와 같은 규칙).
 * - selected: 고른 줄의 lines 위치(null 이면 덩어리의 모든 변경)
 * - reverse: 거꾸로 적용할 패치(언스테이지·버리기). 고르지 않은 '+' 는 문맥으로 두고 '-' 는 뺀다.
 *   앞으로 적용(스테이지)이면 고르지 않은 '-' 를 문맥으로 두고 '+' 는 뺀다.
 */
export function buildPatch(doc: DiffDocument, hunks: number[], selected: Set<number> | null, reverse: boolean): string | null {
  if (!canEditLines(doc)) return null;
  const out = doc.header.filter((l) => !/^(index |old mode |new mode )/.test(l));
  let delta = 0,
    any = false;
  doc.hunks.forEach((h, n) => {
    if (!hunks.includes(n)) return;
    const end = n + 1 < doc.hunks.length ? doc.hunks[n + 1].line : doc.lines.length;
    const body: string[] = [];
    let oldCount = 0,
      newCount = 0,
      changed = false,
      lastKept = false;
    for (let i = h.line + 1; i < end; i++) {
      const l = doc.lines[i];
      const pick = selected ? selected.has(i) : true;
      if (l.kind === "context") {
        body.push(" " + (l.raw ?? ""));
        oldCount++;
        newCount++;
        lastKept = true;
      } else if (l.kind === "removed") {
        if (pick) {
          body.push("-" + (l.raw ?? ""));
          oldCount++;
          changed = lastKept = true;
        } else if (!reverse) {
          body.push(" " + (l.raw ?? ""));
          oldCount++;
          newCount++;
          lastKept = true;
        } else lastKept = false;
      } else if (l.kind === "added") {
        if (pick) {
          body.push("+" + (l.raw ?? ""));
          newCount++;
          changed = lastKept = true;
        } else if (reverse) {
          body.push(" " + (l.raw ?? ""));
          oldCount++;
          newCount++;
          lastKept = true;
        } else lastKept = false;
      } else if (l.kind === "meta" && lastKept) body.push(l.raw ?? ""); // "\ No newline at end of file" 은 앞 줄에 붙는다
    }
    if (!changed) return;
    any = true;
    // 새 쪽 시작 줄: 넣기만 하는 덩어리는 다음 줄부터, 지우기만 하는 덩어리는 앞 줄(git 의 표기 규칙)
    // 역적용의 입력은 새 파일이므로 선택하지 않은 앞 덩어리의 줄 이동도 반영한다.
    const anchor = reverse ? h.newStart + (h.newCount === 0 ? 1 : 0) : h.oldStart + (h.oldCount === 0 ? 1 : 0);
    const oldStart = Math.max(0, anchor + (reverse ? -delta : 0) - (oldCount === 0 ? 1 : 0));
    const newStart = Math.max(0, anchor + (reverse ? 0 : delta) - (newCount === 0 ? 1 : 0));
    out.push(`@@ -${oldStart},${oldCount} +${newStart},${newCount} @@`, ...body);
    delta += newCount - oldCount;
  });
  return any ? out.join("\n") + "\n" : null;
}
