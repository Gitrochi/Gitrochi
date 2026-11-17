/**
 * "Pin to top" by full ref (refs/heads/x, refs/remotes/origin/x, refs/tags/x), so a local branch, a remote branch and a
 * tag of one name never share a pin. Local branches stay stored by name under "pinnedBranches", as they were before
 * remotes and tags could be pinned, so those pins carry over; remote branches and tags are full refs under "pinnedRefs".
 * (macOS: PinnedRefs in Core/BranchFilter.swift)
 */
const heads = "refs/heads/";

export const PinnedRefs = {
  /** The pins of a repository from its two stored lists */
  load: (branches: string[], refs: string[]) => new Set([...branches.map((name) => heads + name), ...refs]),

  /** The two lists to store, in name order */
  split: (pins: Set<string>) => {
    const all = [...pins].sort();
    return { branches: all.filter((r) => r.startsWith(heads)).map((r) => r.slice(heads.length)), refs: all.filter((r) => !r.startsWith(heads)) };
  },
};
