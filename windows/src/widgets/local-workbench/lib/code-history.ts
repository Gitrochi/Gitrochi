/**
 * What the Code page's History, Blame and Working changes views ask Git for, and the rules they share. Reading only:
 * nothing here changes the repository. (macOS: RepositoryCodeHistory)
 */

/** The History list shows this many commits; one more is read to know that there are more */
export const fileHistoryLimit = 200;
/** Blame reads this many lines at most, so a generated file cannot stall the page */
export const blameLineLimit = 5000;

/** The commits that changed a file, following renames, newest first */
export const fileHistoryArgs = (revision: string, path: string, format: string): string[] =>
  ["log", "--follow", "-M", "--name-only", "-z", "-n", String(fileHistoryLimit + 1), "--format=" + format, revision, "--", path];

/** The commits of a revision that are on no remote yet */
export const localCommitArgs = (revision: string): string[] => ["rev-list", "-n", "1000", revision, "--not", "--remotes", "--"];

/** One commit's change to a file against its first parent; a root commit shows the file as added */
export const fileChangeArgs = (commit: string, path: string, ignoreWhitespace: boolean): string[] =>
  ["show", "--format=", "--no-ext-diff", "--no-textconv", "-M", "-m", "--first-parent", ...(ignoreWhitespace ? ["-w"] : []), commit, "--", path];

/** A file's change from one commit to another (the Compare page); a renamed file's old path goes along so the two are paired. macOS: RepositoryCodeHistory.comparisonArgs */
export const comparisonChangeArgs = (base: string, commit: string, path: string, oldPath: string | null, ignoreWhitespace: boolean): string[] =>
  ["diff", "--no-ext-diff", "--no-textconv", "-M", ...(ignoreWhitespace ? ["-w"] : []), base, commit, "--", ...(oldPath && oldPath !== path ? [oldPath] : []), path];

/** The working tree's change to a file against HEAD */
export const workingChangeArgs = (path: string, ignoreWhitespace: boolean): string[] =>
  ["diff", "--no-ext-diff", "--no-textconv", ...(ignoreWhitespace ? ["-w"] : []), "HEAD", "--", path];

export const blameArgs = (revision: string, path: string, lines: number): string[] =>
  ["blame", "--porcelain", "-L", `1,${Math.max(1, Math.min(blameLineLimit, lines))}`, revision, "--", path];

/** The file as a commit has it, for the unchanged lines a diff leaves out */
export const fileAtCommitArgs = (commit: string, path: string): string[] => ["cat-file", "blob", `${commit}:${path}`];

/** The History tab's count: "8", or "200+" when the list stops at the limit */
export const historyCountLabel = (count: number): string => (count > fileHistoryLimit ? `${fileHistoryLimit}+` : String(count));

/**
 * A folder shortened from its start by whole segments ("…/Views/Search"), and nothing when even its last segment does
 * not fit (docs/design.md, Text)
 */
export function shortFolder(folder: string, limit = 20): string {
  if ([...folder].length <= limit) return folder;
  const parts = folder.split("/").filter(Boolean);
  while (parts.length > 1) {
    parts.shift();
    const short = "…/" + parts.join("/");
    if ([...short].length <= limit) return short;
  }
  return "";
}

/**
 * How many leading folders the path bar leaves out so that the rest fits `room` characters; the file name always
 * stays. An estimate from character counts: macOS lays the candidates out and takes the first that fits.
 */
export function droppedFolders(folders: string[], name: string, room: number): number {
  let dropped = 0;
  // each folder brings its " › " along, and the "…" that stands for the dropped ones takes room too
  const width = () => [...name].length + folders.slice(dropped).reduce((sum, folder) => sum + [...folder].length + 3, dropped ? 4 : 0);
  while (dropped < folders.length && width() > room) dropped++;
  return dropped;
}

/**
 * The name beside the short hash on the revision button: the branch for HEAD, what was typed otherwise, and nothing
 * when a hash was typed
 */
export function revisionName(input: string, revision: string, branch: string | null): string | null {
  if (input === "HEAD") return branch;
  return revision.toLowerCase().startsWith(input.toLowerCase()) ? null : input;
}

/** A text's lines as a diff shows them: split at LF only, without the line endings, tabs as four spaces */
export function sourceLines(text: string): string[] {
  const parts = text.split("\n");
  if (parts.at(-1) === "") parts.pop();
  return parts.map((line) => (line.endsWith("\r") ? line.slice(0, -1) : line).replaceAll("\t", "    "));
}

export interface DiffHunkRange { oldStart: number; oldCount: number; newStart: number; newCount: number }
/**
 * Unchanged lines a diff leaves out: `count` lines from `oldStart` and `newStart`, before hunk `hunk` (the number of
 * hunks for the lines after the last one)
 */
export interface DiffGap { hunk: number; oldStart: number; newStart: number; count: number }

export function diffGaps(hunks: DiffHunkRange[], lineCount: number): DiffGap[] {
  const result: DiffGap[] = [];
  let old = 1, next = 1;
  hunks.forEach((hunk, index) => {
    // a hunk with no lines on one side names the line before it
    const firstOld = hunk.oldCount === 0 ? hunk.oldStart + 1 : hunk.oldStart;
    const firstNew = hunk.newCount === 0 ? hunk.newStart + 1 : hunk.newStart;
    if (firstNew > next) result.push({ hunk: index, oldStart: old, newStart: next, count: firstNew - next });
    old = firstOld + hunk.oldCount;
    next = firstNew + hunk.newCount;
  });
  if (lineCount >= next) result.push({ hunk: hunks.length, oldStart: old, newStart: next, count: lineCount - next + 1 });
  return result;
}

/**
 * Where "Blame before this change" goes: the commit's first parent, and the file's name in the next older commit of
 * its history. Nothing when the list has no older commit: the file starts there, or the list stops before it.
 */
export function blameBefore(commit: string, history: { id: string; parent?: string; path: string }[]): { revision: string; path: string } | null {
  const index = history.findIndex((entry) => entry.id === commit), parent = history[index]?.parent;
  if (index < 0 || index + 1 >= history.length || !parent) return null;
  return { revision: parent, path: history[index + 1].path };
}
