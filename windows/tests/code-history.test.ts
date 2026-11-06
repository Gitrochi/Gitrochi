import { describe, expect, it } from "vitest";
import { fileHistoryFormat, parseBlame, parseDiff, parseFileHistory } from "../src/entities/git";
import { blameArgs, blameBefore, blameLineLimit, diffGaps, droppedFolders, fileAtCommitArgs, fileChangeArgs, fileHistoryArgs, fileHistoryLimit, historyCountLabel, localCommitArgs, revisionName, shortFolder, sourceLines, workingChangeArgs } from "../src/widgets/local-workbench/lib/code-history";

// macOS: the same cases are preconditions in macos/Tools/test-repository-browser.sh
describe("Code page history, blame and changes", () => {
  it("asks Git for a bounded history, one commit's change, the working change and a bounded blame", () => {
    expect(fileHistoryArgs("HEAD", "src/a b.ts", fileHistoryFormat)).toEqual(["log", "--follow", "-M", "--name-only", "-z", "-n", String(fileHistoryLimit + 1), "--format=" + fileHistoryFormat, "HEAD", "--", "src/a b.ts"]);
    expect(localCommitArgs("abc")).toEqual(["rev-list", "-n", "1000", "abc", "--not", "--remotes", "--"]);
    expect(fileChangeArgs("abc", "a.ts", false)).toEqual(["show", "--format=", "--no-ext-diff", "--no-textconv", "-M", "-m", "--first-parent", "abc", "--", "a.ts"]);
    expect(fileChangeArgs("abc", "a.ts", true)).toContain("-w");
    expect(workingChangeArgs("a.ts", false)).toEqual(["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", "a.ts"]);
    expect(workingChangeArgs("a.ts", true)).toEqual(["diff", "--no-ext-diff", "--no-textconv", "-w", "HEAD", "--", "a.ts"]);
    expect(blameArgs("abc", "a.ts", 33)).toEqual(["blame", "--porcelain", "-L", "1,33", "abc", "--", "a.ts"]);
    expect(blameArgs("abc", "a.ts", 0)[3]).toBe("1,1");
    expect(blameArgs("abc", "a.ts", 90_000)[3]).toBe(`1,${blameLineLimit}`);
    expect(fileAtCommitArgs("abc", "src/a.ts")).toEqual(["cat-file", "blob", "abc:src/a.ts"]);
  });

  it("labels the History tab's count and stops at the limit", () => {
    expect(historyCountLabel(8)).toBe("8");
    expect(historyCountLabel(fileHistoryLimit)).toBe("200");
    expect(historyCountLabel(fileHistoryLimit + 1)).toBe("200+");
  });

  it("shortens a folder from its start by whole segments, or hides it", () => {
    expect(shortFolder("macos/Sources/Views/Search")).toBe("…/Views/Search");
    expect(shortFolder("src/components")).toBe("src/components");
    expect(shortFolder("")).toBe("");
    expect(shortFolder("a/b/tests", 8)).toBe("…/tests");
    expect(shortFolder("packages/an-extremely-long-folder-name")).toBe("");
    expect(shortFolder("an-extremely-long-folder-name")).toBe("");
  });

  it("drops leading folders from the path bar and always keeps the file name", () => {
    const folders = ["macos", "Sources", "Views", "Search"];
    expect(droppedFolders(folders, "SearchPanel.swift", 80)).toBe(0);
    expect(droppedFolders(folders, "SearchPanel.swift", 44)).toBe(2);
    expect(droppedFolders(folders, "SearchPanel.swift", 5)).toBe(4);
    expect(droppedFolders([], "README.md", 3)).toBe(0);
  });

  it("names the revision beside its hash: the branch for HEAD, the typed name otherwise, nothing for a hash", () => {
    const revision = "c4d5e6f".padEnd(40, "0");
    expect(revisionName("HEAD", revision, "feature/workspace-search")).toBe("feature/workspace-search");
    expect(revisionName("HEAD", revision, null)).toBeNull();
    expect(revisionName("v1.0", revision, "main")).toBe("v1.0");
    expect(revisionName("C4D5E6F", revision, "main")).toBeNull();
    expect(revisionName(revision, revision, "main")).toBeNull();
  });

  it("splits a file into the lines a diff shows", () => {
    expect(sourceLines("a\r\n\tb\n\nc")).toEqual(["a", "    b", "", "c"]);
    expect(sourceLines("a\nb\n")).toEqual(["a", "b"]);
    expect(sourceLines("")).toEqual([]);
  });

  it("finds the unchanged lines a diff leaves out, before, between and after its hunks", () => {
    // the History board: a1b2c3d changes lines 5-11 and 23-44 of a 46-line file
    expect(diffGaps([{ oldStart: 5, oldCount: 7, newStart: 5, newCount: 7 }, { oldStart: 23, oldCount: 15, newStart: 23, newCount: 22 }], 46)).toEqual([
      { hunk: 0, oldStart: 1, newStart: 1, count: 4 }, { hunk: 1, oldStart: 12, newStart: 12, count: 11 }, { hunk: 2, oldStart: 38, newStart: 45, count: 2 }]);
    expect(diffGaps([{ oldStart: 1, oldCount: 2, newStart: 1, newCount: 3 }], 3)).toEqual([]);
    // a new file and a hunk that only removes lines: the side without lines names the line before
    expect(diffGaps([{ oldStart: 0, oldCount: 0, newStart: 1, newCount: 5 }], 5)).toEqual([]);
    expect(diffGaps([{ oldStart: 5, oldCount: 3, newStart: 4, newCount: 0 }], 6)).toEqual([{ hunk: 0, oldStart: 1, newStart: 1, count: 4 }, { hunk: 1, oldStart: 8, newStart: 5, count: 2 }]);
    expect(diffGaps([], 3)).toEqual([{ hunk: 0, oldStart: 1, newStart: 1, count: 3 }]);
  });

  it("sends Blame before this change to the commit's parent and the file's earlier name", () => {
    const history = [{ id: "c", parent: "b", path: "src/new.ts" }, { id: "b", parent: "a", path: "src/new.ts" }, { id: "a", parent: undefined, path: "src/old.ts" }];
    expect(blameBefore("c", history)).toEqual({ revision: "b", path: "src/new.ts" });
    expect(blameBefore("b", history)).toEqual({ revision: "a", path: "src/old.ts" });
    expect(blameBefore("a", history)).toBeNull();
    expect(blameBefore("missing", history)).toBeNull();
  });

  it("reads the formats it asks for through the shared parsers", () => {
    const a = "a".repeat(40), b = "b".repeat(40);
    const history = parseFileHistory([[a, b, "Reword"], [b, "", "Add"]].map(([id, parent, subject]) => `\x1e${[id, parent, "Alex Kim", "alex@example.com", 1_762_300_800, subject].join("\x1f")}\0\nsrc/file.ts\0`).join(""));
    expect(history.map((entry) => [entry.commit.id, entry.commit.parents, entry.commit.subject, entry.path])).toEqual([[a, [b], "Reword", "src/file.ts"], [b, [], "Add", "src/file.ts"]]);
    const blame = parseBlame(`${a} 1 1 1\nauthor Alex Kim\nauthor-mail <alex@example.com>\nauthor-time 1762300800\nsummary Reword\nfilename src/file.ts\n\tfirst\n${b} 2 2 2\nauthor Alex Kim\nauthor-mail <alex@example.com>\nauthor-time 1762300000\nsummary Add\nfilename src/file.ts\n\tsecond\n${b} 3 3\n\tthird\n`);
    expect(blame.map((line) => [line.no, line.sha, line.summary, line.startsBlock])).toEqual([[1, a, "Reword", true], [2, b, "Add", true], [3, b, "Add", false]]);
    const change = parseDiff("diff --git a/src/file.ts b/src/file.ts\n--- a/src/file.ts\n+++ b/src/file.ts\n@@ -2,2 +2,3 @@\n second\n+added\n third\n");
    expect(diffGaps(change.hunks, 6)).toEqual([{ hunk: 0, oldStart: 1, newStart: 1, count: 1 }, { hunk: 1, oldStart: 4, newStart: 5, count: 2 }]);
  });
});
