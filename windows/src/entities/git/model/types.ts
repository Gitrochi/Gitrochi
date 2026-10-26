import { t } from "@/shared/i18n";
import { markdownImageURL, type MdRefs } from "@/shared/lib";
// 맥 버전(Models.swift)과 같은 모델

export const WIP_ID = "__WORKING_TREE__";

export interface Commit {
  id: string;
  parents: string[];
  author: string;
  email: string;
  /** 커밋 날짜(초) */
  date: number;
  subject: string;
  /** 본문 첫 줄(그래프에서 제목 뒤에 흐리게) */
  body?: string;
}

export const isWIP = (c: Commit) => c.id === WIP_ID;
export const isMerge = (c: Commit) => c.parents.length > 1;
export const short = (sha: string) => sha.slice(0, 7);

export function wipCommit(parent: string | null): Commit {
  return { id: WIP_ID, parents: parent ? [parent] : [], author: "", email: "", date: Date.now() / 1000, subject: "" };
}

/** Rows for another worktree's uncommitted changes (GitKraken shows one per worktree) */
const WORKTREE_WIP = "__WORKTREE__:";

export const worktreeWIPCommit = (path: string, parent: string): Commit => ({
  id: WORKTREE_WIP + path,
  parents: [parent],
  author: "",
  email: "",
  date: Date.now() / 1000,
  subject: "",
});

/** The worktree path of such a row, otherwise null */
export const wipWorktree = (c: Commit) => (c.id.startsWith(WORKTREE_WIP) ? c.id.slice(WORKTREE_WIP.length) : null);

/** Uncommitted changes of this or another worktree, not a real commit */
export const isPending = (c: Commit) => isWIP(c) || wipWorktree(c) !== null;

/** What selecting a graph row selects */
export function rowSelection(c: Commit): Selection {
  const wt = wipWorktree(c);
  return isWIP(c) ? { kind: "wip" } : wt !== null ? { kind: "worktree", path: wt } : { kind: "commit", sha: c.id };
}

export const selectionID = (s: Selection | null) =>
  !s ? null : s.kind === "wip" ? WIP_ID : s.kind === "worktree" ? WORKTREE_WIP + s.path : s.kind === "commit" ? s.sha : null;

/** Each file once (conflict, then working tree, then staged), as one list for another worktree */
export function statusFiles(s: WorkingStatus): FileChange[] {
  const seen = new Set<string>();
  return [...s.conflicted, ...s.unstaged, ...s.staged].filter((c) => {
    if (seen.has(c.path)) return false;
    seen.add(c.path);
    return true;
  });
}

export interface CommitDetail {
  sha: string;
  parents: string[];
  author: string;
  email: string;
  date: number;
  committer: string;
  committerEmail: string;
  commitDate: number;
  summary: string;
  body: string;
}

export type RefKind = "head" | "local" | "remote" | "tag";
export const refOrder: Record<RefKind, number> = { head: 0, local: 1, remote: 2, tag: 3 };

export interface RefLabel {
  name: string;
  kind: RefKind;
  isCurrent: boolean;
}

export interface Branch {
  /** 로컬은 "main", 원격은 "origin/main" */
  name: string;
  target: string;
  upstream: string | null;
  ahead: number;
  behind: number;
  upstreamGone: boolean;
  isCurrent: boolean;
  isRemote: boolean;
}

/** 원격 브랜치의 리모트 이름(origin) */
export function branchRemote(b: Branch): string | null {
  if (!b.isRemote) return null;
  const i = b.name.indexOf("/");
  return i < 0 ? b.name : b.name.slice(0, i);
}

/** origin/feature/x → feature/x */
export function branchShort(b: Branch): string {
  if (!b.isRemote) return b.name;
  const i = b.name.indexOf("/");
  return i < 0 ? b.name : b.name.slice(i + 1);
}

export interface Tag {
  name: string;
  target: string;
}

export interface Stash {
  ref: string;
  hash: string;
  message: string;
}

export type ChangeKind = "added" | "modified" | "deleted" | "renamed" | "copied" | "typeChanged" | "untracked" | "conflicted";

export function changeKind(code: string): ChangeKind {
  switch (code) {
    case "A":
      return "added";
    case "D":
      return "deleted";
    case "R":
      return "renamed";
    case "C":
      return "copied";
    case "T":
      return "typeChanged";
    case "U":
      return "conflicted";
    default:
      return "modified";
  }
}

export interface FileChange {
  path: string;
  oldPath: string | null;
  kind: ChangeKind;
  staged: boolean;
}

export const changeId = (c: FileChange) => (c.staged ? "s:" : "w:") + (c.oldPath ? c.oldPath + " → " : "") + c.path;
/** git 명령에 넘길 경로(이름 변경이면 이전 경로 포함) */
export const changePaths = (c: FileChange) => (c.oldPath ? [c.oldPath, c.path] : [c.path]);
export const fileName = (p: string) => p.slice(p.lastIndexOf("/") + 1);
export const fileDir = (p: string) => (p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : "");

export interface WorkingStatus {
  branch: string | null;
  upstream: string | null;
  ahead: number;
  behind: number;
  staged: FileChange[];
  unstaged: FileChange[];
  conflicted: FileChange[];
}

export const emptyStatus = (): WorkingStatus => ({
  branch: null,
  upstream: null,
  ahead: 0,
  behind: 0,
  staged: [],
  unstaged: [],
  conflicted: [],
});

export const statusIsEmpty = (s: WorkingStatus) => !s.staged.length && !s.unstaged.length && !s.conflicted.length;
export const statusCount = (s: WorkingStatus) => new Set([...s.staged, ...s.unstaged, ...s.conflicted].map((c) => c.path)).size;

export type RepoState = "clean" | "merging" | "rebasing" | "cherryPicking" | "reverting";

export const repoStateTitle: Record<RepoState, string> = {
  clean: "",
  merging: t("Merge in progress"),
  rebasing: t("Rebase in progress"),
  cherryPicking: t("Cherry-pick in progress"),
  reverting: t("Revert in progress"),
};

/** 파일 하나의 추가·삭제 줄 수(바이너리면 null) */
export interface LineStat {
  added: number | null;
  deleted: number | null;
}

export interface Identity {
  name: string;
  email: string;
}

export type SearchScope = "commits" | "files" | "code";
export const searchScopes: { id: SearchScope; title: string; prompt: string }[] = [
  { id: "commits", get title() { return t("Commit"); }, get prompt() { return t("Search messages, authors, SHAs, branches (Ctrl+F)"); } },
  { id: "files", get title() { return t("File path"); }, get prompt() { return t("Find commits where a file's name or path changed"); } },
  { id: "code", get title() { return t("Code changes"); }, get prompt() { return t("Find commits that added or removed this code"); } },
];

export type Selection = { kind: "wip" } | { kind: "worktree"; path: string } | { kind: "commit"; sha: string } | { kind: "pullRequest"; number: number };

export type DiffSource =
  | { kind: "working"; change: FileChange }
  | { kind: "commit"; sha: string; change: FileChange; parent: string | null }
  /** PR·MR 에서 바뀐 파일(서버가 준 패치) */
  | { kind: "review"; number: number; change: FileChange; patch: string }
  /** Another worktree's uncommitted change, against its HEAD (read-only) */
  | { kind: "worktree"; path: string; change: FileChange };

export function sameDiffSource(a: DiffSource | null, b: DiffSource | null) {
  if (!a || !b) return a === b;
  if (a.kind !== b.kind) return false;
  if (changeId(a.change) !== changeId(b.change)) return false;
  if (a.kind === "commit") return b.kind === "commit" && a.sha === b.sha;
  if (a.kind === "review") return b.kind === "review" && a.number === b.number;
  if (a.kind === "worktree") return b.kind === "worktree" && a.path === b.path;
  return true;
}

export type DiffKind = "context" | "added" | "removed" | "hunk" | "meta";

export interface DiffLine {
  kind: DiffKind;
  /** 화면용(탭을 공백으로 편 것) */
  text: string;
  oldNo: number | null;
  newNo: number | null;
  /** 패치용 원문(앞의 +·-·공백 표시는 뺀 것) */
  raw?: string;
  /** 몇 번째 덩어리(@@)에 속하는지 */
  hunk?: number;
  /** 단어 단위로 바뀐 부분([시작, 끝) 글자 위치) */
  changes?: Array<[number, number]>;
}

/** 파일 히스토리 한 줄: 그 파일을 바꾼 커밋과, 그 커밋에서의 파일 경로(이름이 바뀌었을 수 있다) */
export interface FileHistoryEntry {
  commit: Commit;
  path: string;
}

/** blame 한 줄: 그 줄을 마지막으로 바꾼 커밋 */
export interface BlameLine {
  /** 줄 번호(1부터) */
  no: number;
  sha: string;
  text: string;
  author: string;
  email: string;
  /** 유닉스 초 */
  date: number;
  summary: string;
  /** 앞 줄과 다른 커밋이면 true(작성자·날짜는 이 줄에만 보여 준다) */
  startsBlock: boolean;
}

export const isUncommittedLine = (l: BlameLine) => /^0+$/.test(l.sha);

/** 가운데 영역에 띄우는 파일 보기 */
export interface FileInspect {
  mode: "history" | "blame";
  path: string;
  /** blame 할 커밋(null 이면 작업 트리) */
  rev: string | null;
}

/** diff 의 덩어리 하나(@@ -oldStart,oldCount +newStart,newCount @@) */
export interface DiffHunk {
  /** lines 에서 @@ 줄의 위치 */
  line: number;
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
}

export interface DiffDocument {
  lines: DiffLine[];
  isBinary: boolean;
  truncated: boolean;
  error?: string;
  /** 첫 @@ 앞의 원문 머리(diff --git·index·---·+++ …) — 줄 단위 스테이지용 패치에 쓴다 */
  header: string[];
  hunks: DiffHunk[];
  /** 머지 커밋의 결합 diff(@@@) */
  combined?: boolean;
  /** 여러 파일의 변경은 파일 하나의 줄 단위 패치로 만들 수 없다. */
  multipleFiles?: boolean;
  /** 새 파일·지운 파일·이름·권한(diff 머리에서 읽은 것) */
  info?: DiffFileInfo;
}

/** diff 머리의 파일 정보 */
export interface DiffFileInfo {
  newFile?: boolean;
  deletedFile?: boolean;
  oldMode?: string;
  newMode?: string;
  renameFrom?: string;
  renameTo?: string;
  /** 이름 바꾼 파일이 얼마나 같은지(%) */
  similarity?: number;
}

export interface GraphSegment {
  /** x 는 레인 번호, y 는 행 높이 비율(0 위, 0.5 노드, 1 아래) */
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  color: number;
  dashed: boolean;
}

export interface GraphRow {
  column: number;
  color: number;
  segments: GraphSegment[];
  width: number;
}

export interface GraphEntry {
  commit: Commit;
  row: GraphRow;
}

export interface Worktree {
  path: string;
  head: string | null;
  branch: string | null;
  isMain: boolean;
  locked: boolean;
  prunable: boolean;
}

export interface WorktreeStats {
  added: number;
  modified: number;
  deleted: number;
  conflicted: number;
  ahead: number;
  behind: number;
  hasUpstream: boolean;
}

export function worktreeStats(s: WorkingStatus): WorktreeStats {
  const kinds = new Map<string, ChangeKind>();
  for (const c of [...s.conflicted, ...s.staged, ...s.unstaged]) if (!kinds.has(c.path)) kinds.set(c.path, c.kind);
  const st: WorktreeStats = { added: 0, modified: 0, deleted: 0, conflicted: 0, ahead: s.ahead, behind: s.behind, hasUpstream: !!s.upstream };
  for (const k of kinds.values()) {
    if (k === "conflicted") st.conflicted++;
    else if (k === "added" || k === "untracked") st.added++;
    else if (k === "deleted") st.deleted++;
    else st.modified++;
  }
  return st;
}

export const statsClean = (s: WorktreeStats) => s.added + s.modified + s.deleted + s.conflicted === 0;

export type Provider = "github" | "gitlab";

export const providerInfo = {
  github: { title: "GitHub", requestName: "Pull Request", requestShort: "PR", requestsTitle: "Pull Requests" },
  gitlab: { title: "GitLab", requestName: "Merge Request", requestShort: "MR", requestsTitle: "Merge Requests" },
} as const;

export interface HostAccount {
  id: string;
  provider: Provider;
  /** https://github.com, https://gitlab.회사.co.kr */
  server: string;
  username: string;
  name: string | null;
  avatarURL: string | null;
}

export function accountHost(a: HostAccount) {
  try {
    return new URL(a.server).host.toLowerCase();
  } catch {
    return a.server;
  }
}

export const accountApiBase = (a: Pick<HostAccount, "provider" | "server">) =>
  a.provider === "github" ? "https://api.github.com" : a.server + "/api/v4";

/** 열린 저장소의 원격이 가리키는 호스팅 저장소 */
export interface RepoTarget {
  provider: Provider;
  remote: string;
  host: string;
  /** owner/repo, group/sub/repo */
  path: string;
}

/** Where #123, !123 and @name in this repository's PR/MR text point */
export function markdownRefs(t: RepoTarget, imageRef = "HEAD"): MdRefs {
  const web = `https://${t.host}/${t.path}`;
  const user = (name: string) => `https://${t.host}/${name}`;
  return t.provider === "github"
    ? { issue: (n) => `${web}/issues/${n}`, user, image: (src) => markdownImageURL(src, `${web}/`, imageRef, t.provider) }
    : { issue: (n) => `${web}/-/issues/${n}`, request: (n) => `${web}/-/merge_requests/${n}`, user, image: (src) => markdownImageURL(src, `${web}/`, imageRef, t.provider) };
}

/** Images load only from the repository's own server, so a PR can't make the app contact any other host */
export function canLoadImage(t: RepoTarget | null, src: string) {
  if (!t) return false;
  let host: string;
  try {
    const u = new URL(src);
    if (u.protocol !== "https:") return false;
    host = u.hostname.toLowerCase();
  } catch {
    return false;
  }
  return host === t.host.toLowerCase().replace(/:\d+$/, "") || (t.provider === "github" && (host === "github.com" || host.endsWith(".githubusercontent.com")));
}

/** <Markdown> props for this repository: #123 · @name links and allowed images */
export const markdownLinks = (t: RepoTarget | null, imageRef = "HEAD") => (t ? { refs: markdownRefs(t, imageRef), canLoadImage: (src: string) => canLoadImage(t, src) } : {});

export const sameTarget = (a: RepoTarget | null, b: RepoTarget | null) =>
  a === b || (!!a && !!b && a.provider === b.provider && a.remote === b.remote && a.host === b.host && a.path === b.path);

export interface PullRequest {
  number: number;
  title: string;
  author: string;
  source: string;
  target: string;
  url: string;
  isDraft: boolean;
  updated: number | null;
  body: string;
  headSHA: string | null;
  fromFork: boolean;
}

export interface RemoteRepo {
  fullName: string;
  cloneURL: string;
  isPrivate: boolean;
  summary: string | null;
}

export type LoadState = { kind: "idle" } | { kind: "loading" } | { kind: "loaded" } | { kind: "needsAccount" } | { kind: "failed"; message: string };

export type SheetKind =
  | { kind: "clone"; url?: string }
  | { kind: "stash" }
  | { kind: "newBranch"; start: string; label: string }
  | { kind: "tag"; sha: string }
  | { kind: "createPullRequest" }
  | { kind: "pushReview"; branch: string; force: boolean; remoteOverride?: string }
  | { kind: "askChanges" }
  | { kind: "compareRevisions" }
  | { kind: "batchCommits" }
  | { kind: "lineHistory" }
  | { kind: "localWorkflows" }
  | { kind: "workspaceOverview" }
  | { kind: "collaborationInbox" }
  | { kind: "repositoryAssistant" }
  | { kind: "mcpConnection" }
  | { kind: "startAgent"; path: string | null }
  | { kind: "addWorktree"; branch: string | null; start: string | null }
  | { kind: "splitCommits" }
  /** 새 파이프라인(GitLab) / 워크플로 실행(GitHub) */
  | { kind: "runPipeline" }
  /** 커밋 정리(인터랙티브 리베이스) */
  | { kind: "interactiveRebase" }
  /** gitch 자동 백업(되돌리기 · 새 브랜치로 꺼내기) */
  | { kind: "gitchBackups" }
  /** 이 브랜치에서 바뀐 의존(gitch graph diff)의 기준 고르기 */
  | { kind: "graphDiff" }
  /** 의존 규칙 검사 결과(gitch graph check) */
  | { kind: "graphCheck" };

export interface ConfirmRequest {
  title: string;
  message: string;
  actionTitle: string;
  destructive?: boolean;
  action: () => void | Promise<unknown>;
}

export interface DropChoice {
  title: string;
  destructive?: boolean;
  action: () => void | Promise<unknown>;
}

export interface DropRequest {
  title: string;
  message: string;
  choices: DropChoice[];
}

export type PullMode = "standard" | "fastForward" | "merge" | "rebase";
export type ResetMode = "soft" | "mixed" | "hard";

export interface LoadingInfo {
  title: string;
  step: string;
}
