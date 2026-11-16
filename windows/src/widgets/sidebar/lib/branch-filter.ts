/**
 * The pure parts of the Branches tab: grouping branches into folders and narrowing them with the Filter branches
 * field. (macOS: BranchFolders and BranchFilter in Core/BranchFilter.swift)
 */

/** Branches that share the part of their names before the first "/" (feature, fix …) */
export interface BranchFolder<T> {
  name: string;
  branches: T[];
}

export interface BranchFolders<T> {
  /** Branches outside a folder, a folder's only branch among them */
  loose: T[];
  folders: BranchFolder<T>[];
}

/** Groups by the first "/" of `key`; a folder of one stays a loose branch under its whole name */
export function groupFolders<T>(branches: T[], key: (b: T) => string): BranchFolders<T> {
  const loose: T[] = [];
  const by = new Map<string, T[]>();
  for (const b of branches) {
    const k = key(b);
    const i = k.indexOf("/");
    if (i < 0) loose.push(b);
    else {
      const f = k.slice(0, i);
      by.set(f, [...(by.get(f) ?? []), b]);
    }
  }
  const folders: BranchFolder<T>[] = [];
  for (const [name, list] of by) {
    if (list.length === 1) loose.push(list[0]);
    else folders.push({ name, branches: list });
  }
  const nat = (a: string, b: string) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
  loose.sort((a, b) => nat(key(a), key(b)));
  folders.sort((a, b) => nat(a.name, b.name));
  return { loose, folders };
}

/** The name without its folder (feature/auth-jwt → auth-jwt) */
export const leaf = (name: string) => (name.includes("/") ? name.slice(name.indexOf("/") + 1) : name);

/** What the field's text matches with: trimmed, in lower case; "" filters nothing */
export const branchFilterQuery = (text: string) => text.trim().toLowerCase();

/** Whether a branch or tag's whole name (feature/login, origin/main, v1.2.0) contains the query */
export const branchFilterMatches = (name: string, query: string) => !query || name.toLowerCase().includes(query);

/**
 * The folders narrowed to the names that match. A folder keeps its place and its form even with one match left, so
 * the tree does not regroup while typing; a folder without a match is left out.
 */
export function filterFolders<T>(groups: BranchFolders<T>, name: (b: T) => string, query: string): BranchFolders<T> {
  if (!query) return groups;
  const keep = (b: T) => branchFilterMatches(name(b), query);
  return {
    loose: groups.loose.filter(keep),
    folders: groups.folders.map((f) => ({ name: f.name, branches: f.branches.filter(keep) })).filter((f) => f.branches.length > 0),
  };
}

/** How many branches the folders hold */
export const folderCount = <T,>(groups: BranchFolders<T>) => groups.loose.length + groups.folders.reduce((n, f) => n + f.branches.length, 0);
