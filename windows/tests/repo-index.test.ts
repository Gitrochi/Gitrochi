import { beforeEach, describe, expect, it, vi } from "vitest";
import type { IndexRequest, IndexResponse } from "@/shared/api";

const state = vi.hoisted(() => ({ indexCall: vi.fn(), gitPath: "C:\\Git\\cmd\\git.exe" as string | null }));

vi.mock("@/shared/api", () => ({ ipc: { indexCall: state.indexCall } }));
vi.mock("../src/shared/platform/tools", () => ({ tools: { path: () => state.gitPath } }));

import { repoIndex } from "../src/shared/platform/repo-index";

const ok = (result: Record<string, unknown>): IndexResponse => ({ result });
const sha = (c: string) => c.repeat(40);

beforeEach(() => {
  state.indexCall.mockReset();
  state.gitPath = "C:\\Git\\cmd\\git.exe";
});

describe("repository index (macOS: RepoIndex.swift)", () => {
  it("answers commit and file searches from a current index, with the app's git", async () => {
    state.indexCall.mockResolvedValue(ok({ shas: [sha("a"), sha("b")], stale: false, truncated: false }));
    const found = await repoIndex.searchMatches("C:/repo", "commits", "로그 인", "");
    expect(found).toEqual(new Set([sha("a"), sha("b")]));
    const request = state.indexCall.mock.calls[0][0] as IndexRequest;
    expect(request).toEqual({ repo: "C:/repo", git: "C:\\Git\\cmd\\git.exe", command: "match", args: { query: "로그 인", scope: "commits", limit: 20_000 } });

    await repoIndex.searchMatches("C:/repo", "files", "src/lib", "");
    expect((state.indexCall.mock.calls[1][0] as IndexRequest).args).toMatchObject({ scope: "files", query: "src/lib" });
  });

  it("falls back to git (null) when the index is stale, missing, off or failing", async () => {
    state.indexCall.mockResolvedValueOnce(ok({ shas: [sha("a")], stale: true }));
    expect(await repoIndex.searchMatches("C:/repo", "commits", "x", "")).toBeNull();
    state.indexCall.mockResolvedValueOnce({ error: { code: "NOT_INDEXED", message: "no index" } });
    expect(await repoIndex.searchMatches("C:/repo", "commits", "x", "")).toBeNull();
    state.indexCall.mockResolvedValueOnce({ error: { code: "DISABLED", message: "off" } });
    expect(await repoIndex.searchMatches("C:/repo", "files", "x", "")).toBeNull();
    state.indexCall.mockRejectedValueOnce(new Error("backend gone"));
    expect(await repoIndex.searchMatches("C:/repo", "commits", "x", "")).toBeNull();
  });

  it("uses the pickaxe cache for code only while the index is current", async () => {
    state.indexCall
      .mockResolvedValueOnce(ok({ stale: false }))
      .mockResolvedValueOnce(ok({ commits: [{ sha: sha("c") }], cached: true }));
    expect(await repoIndex.searchMatches("C:/repo", "code", "a.b", "a\\.b")).toEqual(new Set([sha("c")]));
    expect((state.indexCall.mock.calls[1][0] as IndexRequest).args).toEqual({ action: "pickaxe", text: "a\\.b", regex: true, limit: 1000 });

    state.indexCall.mockReset();
    state.indexCall.mockResolvedValueOnce(ok({ stale: true }));
    expect(await repoIndex.searchMatches("C:/repo", "code", "a.b", "a\\.b")).toBeNull();
    expect(state.indexCall).toHaveBeenCalledTimes(1);
  });

  it("leaves WSL and network paths to git", async () => {
    expect(await repoIndex.searchMatches("\\\\wsl.localhost\\Ubuntu\\home\\me\\repo", "commits", "x", "")).toBeNull();
    await repoIndex.refresh("\\\\server\\share\\repo");
    expect(state.indexCall).not.toHaveBeenCalled();
  });

  it("folds refresh requests during a pass into one more pass", async () => {
    let finish: (value: IndexResponse) => void = () => {};
    state.indexCall.mockImplementation(() => new Promise<IndexResponse>((resolve) => (finish = resolve)));
    const first = repoIndex.refresh("C:/repo");
    void repoIndex.refresh("C:/repo");
    void repoIndex.refresh("C:/repo");
    expect(state.indexCall).toHaveBeenCalledTimes(1);
    finish(ok({ newCommits: 3 }));
    await vi.waitFor(() => expect(state.indexCall).toHaveBeenCalledTimes(2));
    finish(ok({ newCommits: 0 }));
    await first;
    expect(state.indexCall).toHaveBeenCalledTimes(2);
    expect((state.indexCall.mock.calls[0][0] as IndexRequest).args).toEqual({ limit: 20_000 });
    // Another repository is independent.
    state.indexCall.mockResolvedValue(ok({}));
    await repoIndex.refresh("C:/other");
    expect(state.indexCall).toHaveBeenCalledTimes(3);
  });
});
