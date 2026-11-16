import { describe, expect, it } from "vitest";
import { branchFilterMatches, branchFilterQuery, filterFolders, folderCount, groupFolders, leaf, type BranchFolders } from "../src/widgets/sidebar/lib/branch-filter";

const names = ["main", "feature/workspace-search", "feature/ci-groups", "fix/terminal-focus", "fix/flaky-tests", "release/1.10", "Develop"];
const key = (name: string) => name;
const shape = (groups: BranchFolders<string>) => ({ loose: groups.loose, folders: groups.folders.map((f) => `${f.name}: ${f.branches.map(leaf).join(" ")}`) });

describe("branch folders", () => {
  it("groups by the first slash and leaves a folder of one loose", () => {
    expect(shape(groupFolders(names, key))).toEqual({
      loose: ["Develop", "main", "release/1.10"],
      folders: ["feature: workspace-search ci-groups", "fix: terminal-focus flaky-tests"],
    });
    expect(leaf("feature/auth/jwt")).toBe("auth/jwt");
    expect(leaf("main")).toBe("main");
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
    expect(shape(filterFolders(groups, key, "fix/"))).toEqual({ loose: [], folders: ["fix: terminal-focus flaky-tests"] });
    expect(branchFilterMatches("origin/feature/login", "origin")).toBe(true);
  });

  it("keeps a folder as a folder with one match left and drops the ones without a match", () => {
    const groups = groupFolders(names, key);
    const found = filterFolders(groups, key, "search");
    expect(shape(found)).toEqual({ loose: [], folders: ["feature: workspace-search"] });
    expect(folderCount(found)).toBe(1);
    expect(shape(filterFolders(groups, key, "e"))).toEqual({
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
