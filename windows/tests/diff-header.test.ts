import { describe, expect, it } from "vitest";
import { diffSiblings, emptyStatus, type FileChange } from "../src/entities/git";
import { diffHeaderFolders, diffHeaderFolds } from "../src/shared/ui/diff-header-folds";

const change = (path: string, staged = false): FileChange => ({ path, oldPath: null, kind: "modified", staged });

// macOS: DiffHeader.folders and DiffHeader.folds fold the same way
describe("Diff header", () => {
  it("shortens the folder by whole segments, widest first", () => {
    expect(diffHeaderFolders("macos/Sources/Views/Search/SearchPanel.swift")).toEqual(["…/Views/Search", "…/Search"]);
    expect(diffHeaderFolders("src/components/Row.tsx")).toEqual(["src/components", "…/components"]);
    expect(diffHeaderFolders("docs/search.md")).toEqual(["docs"]);
    expect(diffHeaderFolders("README.md")).toEqual([]);
  });

  it("drops the folder, then the position, then Ask AI and Hide whitespace, and cuts the name last", () => {
    const folds = diffHeaderFolds("a/b/c/file.ts", { position: true, ask: true, whitespace: true });
    expect(folds.map((fold) => [fold.folder, fold.position, fold.ask, fold.whitespace, fold.cut])).toEqual([
      ["…/b/c", true, true, true, false],
      ["…/c", true, true, true, false],
      ["", true, true, true, false],
      ["", false, true, true, false],
      ["", false, false, true, false],
      ["", false, false, false, false],
      ["", false, false, false, true],
    ]);
    // a header without a position or the whitespace toggle (file history) has fewer steps
    expect(diffHeaderFolds("file.ts", { position: false, ask: false, whitespace: false }).map((fold) => fold.cut)).toEqual([false, true]);
  });

  it("orders the working files as their lists do and a commit's files as its list does", () => {
    const status = { ...emptyStatus(), conflicted: [change("z.txt")], unstaged: [change("src/b.ts"), change("a.ts")], staged: [change("docs/c.md", true)] };
    const lists = { status, detailSha: "abc", detailFiles: [change("src/y.ts"), change("x.ts")], tree: false };
    const paths = (source: Parameters<typeof diffSiblings>[0], tree = false) => diffSiblings(source, { ...lists, tree }).map((item) => item.change.path);
    expect(paths({ kind: "working", change: status.unstaged[0] })).toEqual(["z.txt", "src/b.ts", "a.ts", "docs/c.md"]);
    // the tree draws folders before files, group by group
    expect(paths({ kind: "working", change: status.unstaged[0] }, true)).toEqual(["z.txt", "src/b.ts", "a.ts", "docs/c.md"]);
    expect(paths({ kind: "commit", sha: "abc", change: lists.detailFiles[1], parent: null })).toEqual(["src/y.ts", "x.ts"]);
    expect(diffSiblings({ kind: "commit", sha: "abc", change: lists.detailFiles[1], parent: "p" }, lists).every((item) => item.kind === "commit" && item.sha === "abc" && item.parent === "p")).toBe(true);
    // another commit's diff, a request's file and another worktree's file have no list beside them
    expect(paths({ kind: "commit", sha: "other", change: change("x.ts"), parent: null })).toEqual([]);
    expect(paths({ kind: "review", number: 1, change: change("x.ts"), patch: "" })).toEqual([]);
    expect(paths({ kind: "worktree", path: "/w", change: change("x.ts") })).toEqual([]);
  });
});
