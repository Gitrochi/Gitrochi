import { describe, expect, it } from "vitest";
import { layoutGraph } from "@/entities/git/lib/graph";
import { type Commit, emptyStatus, type FileChange, isPending, rowSelection, selectionID, statusFiles, wipCommit, wipWorktree, worktreeWIPCommit } from "@/entities/git/model/types";

const commit = (id: string, parents: string[]): Commit => ({ id, parents, author: "a", email: "a@example.com", date: 0, subject: id });
const change = (path: string, kind: FileChange["kind"], staged = false): FileChange => ({ path, kind, staged }) as FileChange;

describe("other worktrees' rows", () => {
  it("draw a dashed line from each row down to that worktree's HEAD", () => {
    const commits = [wipCommit("c"), worktreeWIPCommit("/r-worktrees/feature", "b"), commit("c", ["b"]), commit("b", ["a"]), commit("a", [])];
    const { rows } = layoutGraph(commits);
    expect(rows[1].column).not.toBe(rows[0].column);
    expect(rows[1].segments.some((s) => s.dashed && s.y1 === 0.5)).toBe(true);
    // the dashed lane ends at b, where it joins the main line
    expect(rows[3].column).toBe(rows[2].column);
    expect(rows[3].segments.some((s) => s.dashed && s.x1 === rows[1].column && s.x2 === rows[3].column)).toBe(true);
  });

  it("select and identify the worktree, not a commit", () => {
    const row = worktreeWIPCommit("/r-worktrees/feature", "b");
    expect(isPending(row) && isPending(wipCommit(null)) && !isPending(commit("b", []))).toBe(true);
    expect(wipWorktree(row)).toBe("/r-worktrees/feature");
    expect(rowSelection(row)).toEqual({ kind: "worktree", path: "/r-worktrees/feature" });
    expect(selectionID(rowSelection(row))).toBe(row.id);
    expect(rowSelection(commit("b", []))).toEqual({ kind: "commit", sha: "b" });
  });

  it("list each changed file once, conflicts and working tree first", () => {
    const s = { ...emptyStatus(), staged: [change("a.ts", "modified", true), change("new.ts", "added", true)], unstaged: [change("a.ts", "modified"), change("u.txt", "untracked")], conflicted: [change("c.ts", "conflicted")] };
    expect(statusFiles(s).map((c) => `${c.path}:${c.kind}:${c.staged}`)).toEqual(["c.ts:conflicted:false", "a.ts:modified:false", "u.txt:untracked:false", "new.ts:added:true"]);
  });
});
