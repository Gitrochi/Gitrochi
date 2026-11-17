import { describe, expect, it } from "vitest";
import { PinnedRefs } from "../src/entities/repo/lib/pinned-refs";
import { branchFilterMatches, branchFilterQuery, filterFolders, folderCount, groupFolders, leaf, pinnedFirst, type BranchFolders } from "../src/widgets/sidebar/lib/branch-filter";

const names = ["main", "feature/workspace-search", "feature/ci-groups", "fix/terminal-focus", "fix/flaky-tests", "release/1.10", "Develop"];
const key = (name: string) => name;
const shape = (groups: BranchFolders<string>) => ({ pinned: groups.pinned, loose: groups.loose, folders: groups.folders.map((f) => `${f.name}: ${f.branches.map(leaf).join(" ")}`) });

describe("branch folders", () => {
  it("groups by the first slash and leaves a folder of one loose", () => {
    expect(shape(groupFolders(names, key))).toEqual({
      pinned: [],
      loose: ["Develop", "main", "release/1.10"],
      folders: ["feature: workspace-search ci-groups", "fix: terminal-focus flaky-tests"],
    });
    expect(leaf("feature/auth/jwt")).toBe("auth/jwt");
    expect(leaf("main")).toBe("main");
  });
});

// "Pin to top" (macOS: checkPinnedGrouping in Tools/fixtures/SidebarTreeLayout.swift checks the same cases)
describe("pinned branches", () => {
  const local = ["develop", "feature/checkout", "feature/reviews", "feature/search", "fix/flaky", "fix/focus", "main", "release/1.10"];
  const pins = new Set(["main", "feature/search", "feature/checkout", "fix/flaky", "fix/focus"]);
  const group = (pinned: Set<string>) => groupFolders(local, key, (b) => pinned.has(b));

  it("lead in name order under their whole names, out of their folders, and an emptied folder goes", () => {
    const groups = group(pins);
    expect(shape(groups)).toEqual({
      pinned: ["feature/checkout", "feature/search", "fix/flaky", "fix/focus", "main"],
      loose: ["develop", "release/1.10"],
      folders: ["feature: reviews"],
    });
    // shown once: every branch is in exactly one place, and the section's count still holds them all
    expect([...groups.pinned, ...groups.loose, ...groups.folders.flatMap((f) => f.branches)].sort()).toEqual([...local].sort());
    expect(folderCount(groups)).toBe(local.length);
  });

  it("leave the tree as it was when nothing is pinned", () => {
    expect(shape(group(new Set()))).toEqual({
      pinned: [],
      loose: ["develop", "main", "release/1.10"],
      folders: ["feature: checkout reviews search", "fix: flaky focus"],
    });
  });

  it("are narrowed by name like any other row, and a match stays first", () => {
    const groups = group(pins);
    expect(shape(filterFolders(groups, key, "search"))).toEqual({ pinned: ["feature/search"], loose: [], folders: [] });
    expect(shape(filterFolders(groups, key, "e"))).toEqual({
      pinned: ["feature/checkout", "feature/search"],
      loose: ["develop", "release/1.10"],
      folders: ["feature: reviews"],
    });
    expect(folderCount(filterFolders(groups, key, "search"))).toBe(1);
  });

  it("go back to their folder when unpinned", () => {
    const unpinned = new Set(pins);
    unpinned.delete("feature/search");
    expect(shape(group(unpinned))).toEqual({
      pinned: ["feature/checkout", "fix/flaky", "fix/focus", "main"],
      loose: ["develop", "release/1.10"],
      folders: ["feature: reviews search"],
    });
  });
});

// a remote's branches are grouped by their names within the remote, as the sidebar does with branchShort
describe("pinned remote branches", () => {
  const remote = ["origin/main", "origin/feature/checkout", "origin/feature/reviews", "origin/feature/search", "origin/fix/flaky", "origin/fix/focus"];
  const short = (name: string) => name.slice(name.indexOf("/") + 1);
  const remoteShape = (groups: BranchFolders<string>) => ({
    pinned: groups.pinned.map(short),
    loose: groups.loose.map(short),
    folders: groups.folders.map((f) => `${f.name}: ${f.branches.map((b) => leaf(short(b))).join(" ")}`),
  });

  it("lead their remote by their names there, out of their folders, and an emptied folder goes", () => {
    const groups = groupFolders(remote, short, (b) => ["origin/feature/search", "origin/fix/flaky", "origin/fix/focus"].includes(b));
    expect(remoteShape(groups)).toEqual({ pinned: ["feature/search", "fix/flaky", "fix/focus"], loose: ["main"], folders: ["feature: checkout reviews"] });
    // the folder counts what it holds, the remote every branch
    expect(groups.folders[0].branches).toHaveLength(2);
    expect(folderCount(groups)).toBe(remote.length);
  });

  it("are narrowed by their whole names, and a match stays first in its remote", () => {
    const groups = groupFolders(remote, short, (b) => b === "origin/feature/search");
    expect(remoteShape(filterFolders(groups, key, "origin/feature/s"))).toEqual({ pinned: ["feature/search"], loose: [], folders: [] });
    expect(remoteShape(filterFolders(groups, key, "e"))).toEqual({ pinned: ["feature/search"], loose: [], folders: ["feature: checkout reviews"] });
  });
});

describe("pinned tags", () => {
  const tags = ["v2.0.0", "v1.10.0", "v1.9.0", "nightly"];
  const pinned = new Set(["v1.9.0", "nightly", "v1.10.0"]);

  it("lead Tags in name order, and the rest keep their order", () => {
    expect(pinnedFirst(tags, key, (t) => pinned.has(t))).toEqual(["nightly", "v1.9.0", "v1.10.0", "v2.0.0"]);
    expect(pinnedFirst(tags, key, () => false)).toEqual(tags);
  });

  it("are narrowed by name, and a match stays first", () => {
    const shown = (query: string) => pinnedFirst(tags.filter((t) => branchFilterMatches(t, query)), key, (t) => pinned.has(t));
    expect(shown("v1.1")).toEqual(["v1.10.0"]);
    expect(shown("v")).toEqual(["v1.9.0", "v1.10.0", "v2.0.0"]);
  });
});

// macOS: PinnedRefs in Core/BranchFilter.swift, checked by Tools/fixtures/SidebarTreeLayout.swift
describe("pinned refs", () => {
  it("keep the pins stored before remotes and tags could be pinned as local branches", () => {
    expect([...PinnedRefs.load(["main", "feature/search"], [])].sort()).toEqual(["refs/heads/feature/search", "refs/heads/main"]);
    expect(PinnedRefs.load([], []).size).toBe(0);
  });

  it("never share a pin between a local branch, a remote branch and a tag of one name", () => {
    // a local branch may even be called origin/main
    const pins = PinnedRefs.load(["v1.0", "origin/main"], ["refs/tags/main"]);
    expect(pins.has("refs/heads/v1.0") && !pins.has("refs/tags/v1.0")).toBe(true);
    expect(pins.has("refs/heads/origin/main") && !pins.has("refs/remotes/origin/main")).toBe(true);
    expect(pins.has("refs/tags/main") && !pins.has("refs/heads/main")).toBe(true);
  });

  it("store local branches by name and the rest as full refs, and read back what they stored", () => {
    const pins = new Set(["refs/tags/v1.0", "refs/heads/main", "refs/remotes/origin/main", "refs/heads/v1.0"]);
    const stored = PinnedRefs.split(pins);
    expect(stored).toEqual({ branches: ["main", "v1.0"], refs: ["refs/remotes/origin/main", "refs/tags/v1.0"] });
    expect(PinnedRefs.load(stored.branches, stored.refs)).toEqual(pins);
  });
});

describe("branch filter", () => {
  it("matches with the trimmed text in lower case", () => {
    expect(branchFilterQuery("  Search ")).toBe("search");
    expect(branchFilterQuery("   ")).toBe("");
    expect(branchFilterMatches("feature/Workspace-Search", "search")).toBe(true);
    expect(branchFilterMatches("origin/main", "search")).toBe(false);
    expect(branchFilterMatches("anything", "")).toBe(true);
  });

  it("matches the whole name, so a folder or a remote finds everything in it", () => {
    const groups = groupFolders(names, key);
    expect(shape(filterFolders(groups, key, "fix/"))).toEqual({ pinned: [], loose: [], folders: ["fix: terminal-focus flaky-tests"] });
    expect(branchFilterMatches("origin/feature/login", "origin")).toBe(true);
  });

  it("keeps a folder as a folder with one match left and drops the ones without a match", () => {
    const groups = groupFolders(names, key);
    const found = filterFolders(groups, key, "search");
    expect(shape(found)).toEqual({ pinned: [], loose: [], folders: ["feature: workspace-search"] });
    expect(folderCount(found)).toBe(1);
    expect(shape(filterFolders(groups, key, "e"))).toEqual({
      pinned: [],
      loose: ["Develop", "release/1.10"],
      folders: ["feature: workspace-search ci-groups", "fix: terminal-focus flaky-tests"],
    });
  });

  it("returns the same folders without a query and nothing when no name matches", () => {
    const groups = groupFolders(names, key);
    expect(filterFolders(groups, key, "")).toBe(groups);
    expect(folderCount(groups)).toBe(names.length);
    const none = filterFolders(groups, key, "zzz");
    expect(folderCount(none)).toBe(0);
    expect(none.folders).toEqual([]);
  });
});
