/** What a file row still shows at one width */
export interface FileRowFold { folder: string; rename: boolean; stats: boolean; cut: boolean }

/**
 * A folder and its shorter forms, each cut at a path separator and never inside a name: "a/b/c/d", "…/b/c/d",
 * "…/c/d", "…/d". No more than the last three segments are tried. macOS: FileRowFold.folders
 */
export function fileRowFolders(folder: string): string[] {
  const parts = folder.split("/").filter(Boolean);
  if (!parts.length) return [];
  const result = [parts.join("/")];
  for (let from = Math.max(1, parts.length - 3); from < parts.length; from++) result.push("…/" + parts.slice(from).join("/"));
  return result;
}

/**
 * The forms a row takes as it narrows, widest first. The name is never cut while anything else can give way: the
 * rename caption goes first, then the folder shortens by whole segments and goes, then the counts; only a name wider
 * than the row itself is cut. macOS: FileRowFold.all
 */
export function fileRowFolds(folder: string, rename: boolean, stats: boolean): FileRowFold[] {
  const folders = fileRowFolders(folder);
  const result: FileRowFold[] = [];
  if (rename) result.push({ folder: folders[0] ?? "", rename: true, stats, cut: false });
  for (const form of folders) result.push({ folder: form, rename: false, stats, cut: false });
  result.push({ folder: "", rename: false, stats, cut: false });
  if (stats) result.push({ folder: "", rename: false, stats: false, cut: false });
  result.push({ folder: "", rename: false, stats: false, cut: true });
  return result;
}
