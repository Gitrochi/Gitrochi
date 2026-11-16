import { describe, expect, it } from "vitest";
import { renameCaption } from "../src/entities/git/lib/file-row";
import { fileRowFolders, fileRowFolds } from "../src/shared/ui/file-row-folds";

describe("the shared file row", () => {
  it("shortens a folder from its start by whole segments, never inside a name", () => {
    expect(fileRowFolders("")).toEqual([]);
    expect(fileRowFolders("docs")).toEqual(["docs"]);
    expect(fileRowFolders("windows/tests")).toEqual(["windows/tests", "…/tests"]);
    expect(fileRowFolders("macos/Sources/Views/Search")).toEqual(["macos/Sources/Views/Search", "…/Sources/Views/Search", "…/Views/Search", "…/Search"]);
    // a deep path tries no more than its last three segments
    expect(fileRowFolders("a/b/c/d/e/f")).toEqual(["a/b/c/d/e/f", "…/d/e/f", "…/e/f", "…/f"]);
  });

  it("gives way in order: the rename caption, the folder, the counts, and the name last", () => {
    const folds = fileRowFolds("docs/guides", true, true);
    expect(folds.map((fold) => [fold.rename, fold.folder, fold.stats, fold.cut])).toEqual([
      [true, "docs/guides", true, false],
      [false, "docs/guides", true, false],
      [false, "…/guides", true, false],
      [false, "", true, false],
      [false, "", false, false],
      [false, "", false, true],
    ]);
    // the name is cut in the last form only
    expect(folds.filter((fold) => fold.cut)).toHaveLength(1);
    expect(folds.at(-1)!.cut).toBe(true);
  });

  it("has no form to try for what a row does not have", () => {
    // a tree row: no folder, no rename, no counts
    expect(fileRowFolds("", false, false)).toEqual([
      { folder: "", rename: false, stats: false, cut: false },
      { folder: "", rename: false, stats: false, cut: true },
    ]);
    expect(fileRowFolds("", false, true).map((fold) => fold.stats)).toEqual([true, false, false]);
    expect(new Set(fileRowFolds("a/b", true, true).map((fold) => JSON.stringify(fold))).size).toBe(fileRowFolds("a/b", true, true).length);
  });

  it("writes a rename as old → new and a copy as copied from", () => {
    expect(renameCaption({ path: "docs/search.md", oldPath: null, kind: "modified" })).toBeNull();
    expect(renameCaption({ path: "docs/search.md", oldPath: "docs/search.md", kind: "renamed" })).toBeNull();
    expect(renameCaption({ path: "docs/search.md", oldPath: "docs/find.md", kind: "renamed" })).toBe("find.md → search.md");
    // only the folder changed: the names alone would say nothing
    expect(renameCaption({ path: "docs/search.md", oldPath: "notes/search.md", kind: "renamed" })).toBe("notes/search.md → search.md");
    expect(renameCaption({ path: "docs/search.md", oldPath: "docs/find.md", kind: "copied" })).toBe("copied from find.md");
  });
});
