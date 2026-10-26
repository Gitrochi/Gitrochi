import { describe, expect, it } from "vitest";
import { batchArguments, fullObjectID, lineHistoryRange, parseLineHistory, toggleGraphSelection, validRevisionInput, type BatchCommitItem } from "@/entities/git/lib/history-tools";
const id = (char: string) => char.repeat(40);
const item = (char: string, parents: string[] = []): BatchCommitItem => ({ sha: id(char), parents, subject: char, message: char, author: "Fixture" });

describe("history tools boundaries", () => {
  it("resolves revision syntax only after rejecting options and controls", () => {
    for (const value of ["HEAD", "HEAD~4", "origin/topic", "v1.2.0", id("a")]) expect(validRevisionInput(value)).toBe(true);
    for (const value of ["", "--output=/tmp/x", " -x", "a\nb", "HEAD\0"]) expect(validRevisionInput(value)).toBe(false);
    expect(fullObjectID(id("a"))).toBe(true);
    expect(fullObjectID("b".repeat(64))).toBe(true);
    expect(fullObjectID("--help")).toBe(false);
  });
  it("supports additive and contiguous graph selection without duplicate IDs", () => {
    const ids = ["a", "b", "c", "d"];
    expect(toggleGraphSelection(ids, ["b"], "b", "d", true, false)).toEqual(["b", "c", "d"]);
    expect(toggleGraphSelection(ids, ["a", "b"], "b", "c", true, true)).toEqual(["a", "b", "c"]);
    expect(toggleGraphSelection(ids, ["a", "b"], "a", "a", false, true)).toEqual(["b"]);
    expect(toggleGraphSelection(ids, ["a", "b"], "a", "d", false, false)).toEqual(["d"]);
  });
  it("keeps execution order and rejects merge commits and untrusted IDs", () => {
    expect(batchArguments("cherry-pick", [item("a"), item("b")])).toEqual(["cherry-pick", id("a"), id("b")]);
    expect(batchArguments("revert", [item("b"), item("a")])).toEqual(["revert", "--no-edit", id("b"), id("a")]);
    expect(() => batchArguments("revert", [item("b", [id("a"), id("c")])])).toThrow(/Merge commits/);
    expect(() => batchArguments("cherry-pick", [{ ...item("a"), sha: "--skip" }])).toThrow();
    expect(() => batchArguments("squash", [item("a")])).toThrow(/cleanup plan/);
  });
  it("builds literal function and numeric line selectors with Unicode paths", () => {
    expect(lineHistoryRange("src/이름 with spaces.swift", 2, 9)).toBe("2,9:src/이름 with spaces.swift");
    expect(lineHistoryRange("file.ts", 1, 1, "load.value")).toBe(":load\\.value:file.ts");
    expect(() => lineHistoryRange("a", 0, 2)).toThrow();
    expect(() => lineHistoryRange("a", 3, 2)).toThrow();
    expect(() => lineHistoryRange("a", 1, 2, "a:b")).toThrow();
  });
  it("parses bounded log-L records without mistaking patch text for commits", () => {
    const records = parseLineHistory(`\x1e${id("a")}\x1fFixture\x1f2026-01-01\x1fChange\n\ndiff --git a/f b/f\n+new\n\x1eignored\n+text\n\x1e${id("b")}\x1fFixture\x1f2025-01-01\x1fCreate\n+old\n`);
    expect(records).toHaveLength(2);
    expect(records[0].patch).toContain("+new");
    expect(records[1].subject).toBe("Create");
  });
});
