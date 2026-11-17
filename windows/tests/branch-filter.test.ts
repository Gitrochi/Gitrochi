import { describe, expect, it } from "vitest";
import { branchFilterMatches, branchFilterQuery, filterFolders, folderCount, groupFolders, leaf, type BranchFolders } from "../src/widgets/sidebar/lib/branch-filter";

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
