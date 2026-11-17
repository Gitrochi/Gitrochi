/** What is still in the row at one width */
export interface DiffHeaderFold { folder: string; position: boolean; ask: boolean; whitespace: boolean; cut: boolean }

/**
 * The folder as the row shows it, widest first: the last two segments behind "…/", then the last one
 * ("macos/Sources/Views/Search" is "…/Views/Search", then "…/Search"). macOS: DiffHeader.folders
 */
export function diffHeaderFolders(path: string): string[] {
  const parts = path.split("/").slice(0, -1).filter(Boolean);
  if (!parts.length) return [];
  const two = parts.length > 2 ? "…/" + parts.slice(-2).join("/") : parts.join("/");
  const one = (parts.length > 1 ? "…/" : "") + parts[parts.length - 1];
  return two === one ? [two] : [two, one];
}

/**
 * The forms the row takes as it narrows: the folder goes first, then the position, then Ask AI… and Hide whitespace
 * move into More, and only then is the name cut. macOS: DiffHeader.folds
 */
export function diffHeaderFolds(path: string, has: { position: boolean; ask: boolean; whitespace: boolean }): DiffHeaderFold[] {
  const all = { position: true, ask: true, whitespace: true, cut: false };
  const result: DiffHeaderFold[] = diffHeaderFolders(path).map((folder) => ({ folder, ...all }));
  let fold: DiffHeaderFold = { folder: "", ...all };
  result.push(fold);
  if (has.position) result.push((fold = { ...fold, position: false }));
  if (has.ask) result.push((fold = { ...fold, ask: false }));
  if (has.whitespace) result.push((fold = { ...fold, whitespace: false }));
  result.push({ ...fold, cut: true });
  return result;
}
