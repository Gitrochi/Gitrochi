import { describe, expect, it } from "vitest";
import { batchArguments, commitCountLabel, comparisonCommitLimit, comparisonKey, comparisonLogArgs, comparisonReferences, fullObjectID, lineHistoryRange, parseComparisonCommits, parseLineHistory, referenceMatches, toggleGraphSelection, validRevisionInput, type BatchCommitItem } from "@/entities/git/lib/history-tools";
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

// macOS: the same cases are preconditions in macos/Tools/test-history-tools.sh
describe("the Compare page", () => {
  it("reads To's commits past the base, one more than it lists", () => {
    expect(comparisonLogArgs(id("a"), id("b"))).toEqual(["log", "-n", String(comparisonCommitLimit + 1), "--format=%H%x1f%an%x1f%ct%x1f%s%x1e", `${id("a")}..${id("b")}`, "--"]);
    const commits = parseComparisonCommits(`${id("a")}\x1fAlex Kim\x1f1762300800\x1fSplit\x1fsubject\x1e\n${id("b")}\x1fSam Lee\x1f\x1fNo time\x1e\nnot a commit\x1e\n`);
    expect(commits).toEqual([{ id: id("a"), author: "Alex Kim", date: 1762300800, subject: "Split\x1fsubject" }, { id: id("b"), author: "Sam Lee", date: null, subject: "No time" }]);
    expect(parseComparisonCommits("")).toEqual([]);
    expect(commitCountLabel(8)).toBe("8");
    expect(commitCountLabel(comparisonCommitLimit)).toBe("200");
    expect(commitCountLabel(comparisonCommitLimit + 1)).toBe("200+");
  });
  it("lists the usual bases first, without the current branch or a remote's HEAD", () => {
    const references = comparisonReferences(["topic", "feature/a", "main"], ["origin/HEAD", "origin/main", "origin/topic"], ["v1.1", "v1.0"], "topic");
    expect(references.map((reference) => reference.name)).toEqual(["origin/main", "main", "feature/a", "origin/topic", "v1.1", "v1.0"]);
    expect(references.map((reference) => reference.kind)).toEqual(["remote", "branch", "branch", "remote", "tag", "tag"]);
    expect(comparisonReferences(["main"], [], [], null).map((reference) => reference.name)).toEqual(["main"]);
    expect(references.filter((reference) => referenceMatches(reference.name, " MAIN ")).map((reference) => reference.name)).toEqual(["origin/main", "main"]);
  });
  it("compares again when a side or the branch it names moves", () => {
    const targets = new Map([["main", id("a")], ["topic", id("b")]]);
    const key = comparisonKey("/repo", "main", "topic", true, id("c"), targets);
    expect(comparisonKey("/repo", "main", "topic", true, id("c"), new Map(targets))).toBe(key);
    expect(comparisonKey("/repo", "main", "topic", true, id("c"), new Map([["main", id("a")], ["topic", id("d")]]))).not.toBe(key);
    expect(comparisonKey("/repo", "main", "topic", false, id("c"), targets)).not.toBe(key);
    expect(comparisonKey("/repo", "topic", "main", true, id("c"), targets)).not.toBe(key);
    expect(comparisonKey("/repo", "main", "topic", true, id("d"), targets)).not.toBe(key);
  });
});
