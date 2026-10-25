import { t } from "@/shared/i18n";
import { type BlameLine, type Branch, changeKind, type Commit, type CommitDetail, type DiffDocument, type DiffFileInfo, type DiffKind, emptyStatus, type FileChange, type FileHistoryEntry, type LineStat, type Stash, type Tag, type WorkingStatus, type Worktree } from "../model/types";
import { markWords } from "./diff";

/** git 의 기계용 출력(porcelain, -z, 커스텀 format)을 모델로 바꾼다. (맥 버전 Parsers.swift 와 같은 규칙) */

// 그래프 날짜는 정렬(--date-order) 기준과 같은 커밋 날짜(%ct)
export const logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%ct%x1f%s%x1f%b%x1e";
export const refFormat = "%(refname)%1f%(objectname)%1f%(*objectname)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(HEAD)";
export const detailFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%B";
export const stashFormat = "%gd%x1f%H%x1f%gs";

const US = "\u001f";
const RS = "\u001e";

const words = (s: string) => s.split(" ").filter(Boolean);
const lines = (s: string) => s.split("\n").filter((l) => l.length > 0);

export function parseLog(text: string): Commit[] {
  const out: Commit[] = [];
  for (const rec of text.split(RS)) {
    const r = rec.replace(/^[\r\n]+/, "");
    if (!r) continue;
    const f = r.split(US);
    if (f.length < 6) continue;
    out.push({ id: f[0], parents: words(f[1]), author: f[2], email: f[3], date: Number(f[4]) || 0, subject: f[5], body: f.length > 6 ? bodyPreview(f.slice(6).join(US)) : "" });
  }
  return out;
}

/** 본문에서 첫 번째 내용 줄(Co-Authored-By 같은 꼬리말은 빼고, 글머리표는 떼고, 길면 자른다) */
export function bodyPreview(body: string): string {
  for (const raw of body.split(/\r?\n/)) {
    let l = raw.trim();
    if (!l || /^[A-Za-z][A-Za-z0-9-]*: \S/.test(l)) continue;
    if (l.startsWith("- ") || l.startsWith("* ")) l = l.slice(2);
    return l.slice(0, 200);
  }
  return "";
}

export function parseCommitDetail(text: string): CommitDetail | null {
  const f = text.split(US);
  if (f.length < 9) return null;
  const message = f.slice(8).join(US).trim();
  const nl = message.indexOf("\n");
  const summary = nl < 0 ? message : message.slice(0, nl);
  const body = message.slice(summary.length).trim();
  return {
    sha: f[0],
    parents: words(f[1]),
    author: f[2],
    email: f[3],
    date: Number(f[4]) || 0,
    committer: f[5],
    committerEmail: f[6],
    commitDate: Number(f[7]) || 0,
    summary,
    body,
  };
}

/** "ahead 2, behind 1" / "gone" */
export function parseTrack(s: string) {
  let ahead = 0,
    behind = 0,
    gone = false;
  for (const part of s.split(",")) {
    const w = words(part.trim());
    if (w[0] === "gone") gone = true;
    if (w.length === 2) {
      const n = Number(w[1]);
      if (w[0] === "ahead") ahead = n;
      else if (w[0] === "behind") behind = n;
    }
  }
  return { ahead, behind, gone };
}

const naturalDesc = (a: string, b: string) => b.localeCompare(a, undefined, { numeric: true, sensitivity: "base" });

export function parseRefs(text: string): { locals: Branch[]; remotes: Branch[]; tags: Tag[] } {
  const locals: Branch[] = [];
  const remotes: Branch[] = [];
  const tags: Tag[] = [];
  for (const line of lines(text)) {
    const f = line.split(US);
    if (f.length < 6) continue;
    const [ref, obj, peeled, upstream, track] = f;
    if (ref.startsWith("refs/heads/")) {
      const item = parseTrack(track);
      locals.push({
        name: ref.slice(11),
        target: obj,
        upstream: upstream || null,
        ahead: item.ahead,
        behind: item.behind,
        upstreamGone: item.gone,
        isCurrent: f[5].trim() === "*",
        isRemote: false,
      });
    } else if (ref.startsWith("refs/remotes/")) {
      const name = ref.slice(13);
      if (name.endsWith("/HEAD")) continue;
      remotes.push({ name, target: obj, upstream: null, ahead: 0, behind: 0, upstreamGone: false, isCurrent: false, isRemote: true });
    } else if (ref.startsWith("refs/tags/")) {
      tags.push({ name: ref.slice(10), target: peeled || obj });
    }
  }
  tags.sort((a, b) => naturalDesc(a.name, b.name));
  return { locals, remotes, tags };
}

export function parseStashes(text: string): Stash[] {
  return lines(text)
    .map((l) => l.split(US))
    .filter((f) => f.length >= 3)
    .map((f) => ({ ref: f[0], hash: f[1], message: f[2] }));
}

/** `git remote -v` → 이름 순서와 fetch URL */
export function parseRemotes(text: string): { names: string[]; urls: Record<string, string> } {
  const names: string[] = [];
  const urls: Record<string, string> = {};
  for (const line of lines(text)) {
    const parts = line.split(/[\t ]+/).filter(Boolean);
    if (parts.length < 2) continue;
    const name = parts[0];
    if (!names.includes(name)) names.push(name);
    if (parts.length < 3 || parts[2] === "(fetch)") urls[name] = parts[1];
  }
  return { names, urls };
}

/** `git worktree list --porcelain -z` (이전 줄 구분 출력도 읽는다) */
export function parseWorktrees(text: string): Worktree[] {
  const out: Worktree[] = [];
  const nul = text.includes("\0");
  (nul ? text : text.replace(/\r\n/g, "\n"))
    .split(nul ? "\0\0" : "\n\n")
    .forEach((block, i) => {
      let path: string | null = null,
        head: string | null = null,
        branch: string | null = null;
      let locked = false,
        prunable = false,
        bare = false;
      for (const line of block.split(nul ? "\0" : "\n")) {
        if (line.startsWith("worktree ")) path = line.slice(9);
        else if (line.startsWith("HEAD ")) head = line.slice(5);
        else if (line.startsWith("branch ")) {
          const ref = line.slice(7);
          branch = ref.startsWith("refs/heads/") ? ref.slice(11) : ref;
        } else if (line === "bare") bare = true;
        else if (line.startsWith("locked")) locked = true;
        else if (line.startsWith("prunable")) prunable = true;
      }
      if (!path || bare) return;
      out.push({ path, head, branch, isMain: i === 0, locked, prunable });
    });
  return out;
}

/** status --porcelain=v2 -z --branch */
export function parseStatus(text: string): WorkingStatus {
  const st = emptyStatus();
  const tokens = text.split("\0").filter((text2) => text2.length > 0);
  let i = 0;

  const add = (xy: string, path: string, orig: string | null) => {
    if (xy.length !== 2) return;
    if (xy[0] !== ".") st.staged.push({ path, oldPath: orig, kind: changeKind(xy[0]), staged: true });
    if (xy[1] !== ".") st.unstaged.push({ path, oldPath: null, kind: changeKind(xy[1]), staged: false });
  };
  /** 공백으로 n 칸 나누고 나머지는 경로(경로에 공백이 있을 수 있음) */
  const splitN = (text2: string, n: number) => {
    const out: string[] = [];
    let rest = text2;
    for (let k = 0; k < n - 1; k++) {
      const sp = rest.indexOf(" ");
      if (sp < 0) break;
      out.push(rest.slice(0, sp));
      rest = rest.slice(sp + 1);
    }
    out.push(rest);
    return out;
  };

  while (i < tokens.length) {
    const text2 = tokens[i++];
    if (text2.startsWith("# ")) {
      const body = text2.slice(2);
      const sp = body.indexOf(" ");
      if (sp < 0) continue;
      const key = body.slice(0, sp),
        val = body.slice(sp + 1);
      if (key === "branch.head") st.branch = val === "(detached)" ? null : val;
      else if (key === "branch.upstream") st.upstream = val;
      else if (key === "branch.ab") {
        for (const w of words(val)) {
          if (w.startsWith("+")) st.ahead = Number(w.slice(1)) || 0;
          if (w.startsWith("-")) st.behind = Number(w.slice(1)) || 0;
        }
      }
    } else if (text2.startsWith("1 ")) {
      const f = splitN(text2, 9);
      if (f.length === 9) add(f[1], f[8], null);
    } else if (text2.startsWith("2 ")) {
      const f = splitN(text2, 10);
      const orig = i < tokens.length ? tokens[i] : null;
      i++;
      if (f.length === 10) add(f[1], f[9], orig);
    } else if (text2.startsWith("u ")) {
      const f = splitN(text2, 11);
      if (f.length === 11) st.conflicted.push({ path: f[10], oldPath: null, kind: "conflicted", staged: false });
    } else if (text2.startsWith("? ")) {
      st.unstaged.push({ path: text2.slice(2), oldPath: null, kind: "untracked", staged: false });
    }
  }
  return st;
}

/** --name-status -z */
export function parseNameStatus(text: string): FileChange[] {
  const tokens = text.split("\0").filter((text2) => text2.length > 0);
  const out: FileChange[] = [];
  let i = 0;
  while (i < tokens.length) {
    const code = tokens[i++];
    const c = code[0];
    if (!c) continue;
    if (c === "R" || c === "C") {
      if (i + 1 >= tokens.length) break;
      out.push({ path: tokens[i + 1], oldPath: tokens[i], kind: c === "R" ? "renamed" : "copied", staged: false });
      i += 2;
    } else {
      if (i >= tokens.length) break;
      out.push({ path: tokens[i], oldPath: null, kind: changeKind(c), staged: false });
      i++;
    }
  }
  return out;
}

/** --numstat -z: "추가\t삭제\t경로\0", 이름 변경은 "추가\t삭제\t\0이전\0새\0" */
export function parseNumstat(text: string): Record<string, LineStat> {
  const tokens = text.split("\0");
  const out: Record<string, LineStat> = {};
  let i = 0;
  while (i < tokens.length) {
    const text2 = tokens[i++].replace(/^\n/, "");
    const a = text2.indexOf("\t");
    const b = a < 0 ? -1 : text2.indexOf("\t", a + 1);
    if (a < 0 || b < 0) continue;
    const num = (s: string) => (/^\d+$/.test(s) ? Number(s) : null);
    const stat: LineStat = { added: num(text2.slice(0, a)), deleted: num(text2.slice(a + 1, b)) };
    const path = text2.slice(b + 1);
    if (!path) {
      if (i + 1 >= tokens.length) break;
      out[tokens[i + 1]] = stat;
      i += 2;
    } else {
      out[path] = stat;
    }
  }
  return out;
}

function hunkStart(s: string, sign: string) {
  const m = s.match(new RegExp(` \\${sign}(\\d+)`));
  return m ? Number(m[1]) : 0;
}

function hunkCount(s: string, sign: string) {
  const m = s.match(new RegExp(` \\${sign}\\d+(?:,(\\d+))?`));
  return m ? (m[1] === undefined ? 1 : Number(m[1])) : 0;
}

export function parseDiff(text: string, maxLines = 20000): DiffDocument {
  const doc: DiffDocument = { lines: [], isBinary: false, truncated: false, header: [], hunks: [] };
  // 줄 끝의 \r(CRLF 파일)은 화면에서는 빼고, 줄 단위 스테이지 패치용 원문(raw)에는 남긴다
  let body = text;
  if (body.endsWith("\n")) body = body.slice(0, -1);
  if (!body) return doc;

  let oldNo = 0,
    newNo = 0,
    inHunk = false,
    cols = 1,
    files = 0;
  const info: DiffFileInfo = {};
  doc.info = info;
  const push = (kind: DiffKind, text2: string, o: number | null, n: number | null, raw = "") =>
    doc.lines.push({ kind, text: text2, oldNo: o, newNo: n, raw, hunk: doc.hunks.length ? doc.hunks.length - 1 : undefined });

  for (const line of body.split("\n")) {
    if (doc.lines.length >= maxLines) {
      doc.truncated = true;
      break;
    }
    const cr = line.endsWith("\r");
    const s = cr ? line.slice(0, -1) : line;
    if (s.startsWith("@@")) {
      inHunk = true;
      cols = Math.max(1, (s.match(/^@+/)?.[0].length ?? 2) - 1); // "@@" 1열, 결합 diff "@@@" 2열
      if (cols > 1) doc.combined = true;
      oldNo = hunkStart(s, "-");
      newNo = hunkStart(s, "+");
      doc.hunks.push({ line: doc.lines.length, oldStart: oldNo, oldCount: hunkCount(s, "-"), newStart: newNo, newCount: hunkCount(s, "+") });
      push("hunk", s, null, null);
      continue;
    }
    if (s.startsWith("diff ")) {
      inHunk = false;
      files++;
      if (files > 1) doc.multipleFiles = true;
    }
    if (!inHunk) {
      if (files <= 1) {
        doc.header.push(s);
        readInfo(s, info);
      }
      if (s.startsWith("Binary files") || s.startsWith("GIT binary patch")) doc.isBinary = true;
      continue;
    }
    if (s.startsWith("\\")) {
      push("meta", t("No newline at end of file"), null, null, s);
      continue;
    }
    const marker = s.slice(0, cols);
    const raw = line.slice(cols);
    const content = s.slice(cols).replace(/\t/g, "    ");
    if (marker.includes("+") && !marker.includes("-")) {
      push("added", content, null, newNo++, raw);
    } else if (marker.includes("-")) {
      push("removed", content, oldNo++, null, raw);
    } else {
      push("context", content, oldNo++, newNo++, raw);
    }
  }
  markWords(doc.lines);
  return doc;
}

/** diff 머리 한 줄에서 새 파일·지운 파일·권한·이름 바꿈을 읽는다 */
function readInfo(s: string, info: DiffFileInfo) {
  const rest = (prefix: string) => (s.startsWith(prefix) ? s.slice(prefix.length) : null);
  let v: string | null;
  if ((v = rest("new file mode ")) !== null) {
    info.newFile = true;
    info.newMode = v;
  } else if ((v = rest("deleted file mode ")) !== null) {
    info.deletedFile = true;
    info.oldMode = v;
  } else if ((v = rest("old mode ")) !== null) info.oldMode = v;
  else if ((v = rest("new mode ")) !== null) info.newMode = v;
  else if ((v = rest("rename from ")) !== null) info.renameFrom = v;
  else if ((v = rest("rename to ")) !== null) info.renameTo = v;
  else if ((v = rest("similarity index ")) !== null) info.similarity = parseInt(v, 10);
}

/** 추적하지 않는 새 파일: 내용 전체를 추가된 줄로 */
export function newFileDiff(text: string, truncated: boolean, maxLines = 20000): DiffDocument {
  const doc: DiffDocument = { lines: [], isBinary: false, truncated, header: [], hunks: [], info: { newFile: true } };
  if (!text) return doc;
  let body = text.replace(/\r\n/g, "\n");
  if (body.endsWith("\n")) body = body.slice(0, -1);
  const all = body.split("\n");
  doc.lines.push({ kind: "hunk", text: `@@ -0,0 +1,${all.length} @@`, oldNo: null, newNo: null });
  all.slice(0, maxLines).forEach((l, i) => doc.lines.push({ kind: "added", text: l.replace(/\t/g, "    "), oldNo: null, newNo: i + 1 }));
  if (all.length > maxLines) doc.truncated = true;
  return doc;
}

// MARK: - 파일 히스토리 · blame

/** git log --follow --name-only 와 함께 쓰는 형식(커밋마다 \x1e 로 시작) */
export const fileHistoryFormat = "%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%ct%x1f%s";

export function parseFileHistory(text: string): FileHistoryEntry[] {
  const records: { header: string; path: string }[] = [];
  if (text.includes("\0")) {
    const fields = text.split("\0");
    for (let i = 0; i < fields.length; i++) {
      if (!fields[i].startsWith(RS)) continue;
      const header = fields[i].slice(1);
      const path = fields[i + 1]?.startsWith("\n") ? fields[++i].slice(1) : "";
      records.push({ header, path });
    }
  } else {
    for (const rec of text.split(RS).filter((r) => r.trim())) {
      const parts = rec.split(/\r?\n/).filter(Boolean);
      records.push({ header: parts[0] ?? "", path: parts[1] ?? "" });
    }
  }
  return records.flatMap(({ header, path }): FileHistoryEntry[] => {
    const f = header.split(US);
    if (f.length < 6) return [];
    const commit: Commit = { id: f[0], parents: f[1] ? f[1].split(" ") : [], author: f[2], email: f[3], date: Number(f[4]) || 0, subject: f.slice(5).join(US) };
    return [{ commit, path }];
  });
}

/** git blame --porcelain */
export function parseBlame(text: string): BlameLine[] {
  const infos = new Map<string, { author: string; email: string; time: number; summary: string }>();
  const out: BlameLine[] = [];
  let sha = "",
    lineNo = 0,
    prev = "";
  for (const raw of text.split("\n")) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (line.startsWith("\t")) {
      const info = infos.get(sha) ?? { author: "", email: "", time: 0, summary: "" };
      out.push({ no: lineNo, sha, text: line.slice(1).replace(/\t/g, "    "), author: info.author, email: info.email, date: info.time, summary: info.summary, startsBlock: sha !== prev });
      prev = sha;
      continue;
    }
    const sp = line.indexOf(" ");
    const key = sp < 0 ? line : line.slice(0, sp);
    const value = sp < 0 ? "" : line.slice(sp + 1);
    if (/^[0-9a-f]{40}$|^[0-9a-f]{64}$/.test(key)) {
      sha = key;
      lineNo = Number(value.split(" ")[1]) || lineNo + 1;
      if (!infos.has(sha)) infos.set(sha, { author: "", email: "", time: 0, summary: "" });
      continue;
    }
    const info = infos.get(sha);
    if (!info) continue;
    if (key === "author") info.author = value;
    else if (key === "author-mail") info.email = value.replace(/^<|>$/g, "");
    else if (key === "author-time") info.time = Number(value) || 0;
    else if (key === "summary") info.summary = value;
  }
  return out;
}
