import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
vi.mock("@/shared/platform/git", () => ({ git: vi.fn() }));

import { layoutGraph, wipCommit, type Commit } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { git } from "@/shared/platform";

const commit = (id: string, subject: string): Commit => ({ id, subject, parents: [], author: "Demo", email: "demo@example.com", date: 0 });
function storeForSearch(commits: Commit[]) {
  const store = new RepoStore();
  store.path = "C:/repo";
  const { rows } = layoutGraph(commits);
  store.entries = commits.map((commit, i) => ({ commit, row: rows[i] }));
  vi.spyOn(store, "select").mockImplementation(() => {});
  return store;
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.mocked(git).mockResolvedValue({ status: 0, stdout: "", stderr: "" });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); });

describe("커밋 검색", () => {
  it.each(["정리1", "정리 1", " 정 리\t1 "])("공백 위치와 관계없이 제목을 즉시 찾는다: %j", (query) => {
    const store = storeForSearch([commit("a", "정리 1"), commit("b", "정리1"), commit("c", "정리 2"), { ...wipCommit(null), subject: "정리 1" }]);
    store.setSearch(query);
    expect(store.searchMatches).toEqual(["a", "b"]);
  });

  it("작성자·이메일·브랜치·SHA에도 같은 규칙을 적용한다", () => {
    const store = storeForSearch([
      { ...commit("a", "one"), author: "Jun Ha" },
      { ...commit("b", "two"), email: "junha@example.com" },
      commit("c", "three"), commit("abc123", "four"),
    ]);
    store.refsByCommit.set("c", [{ name: "feature/junha", kind: "local", isCurrent: false }]);
    store.setSearch("JUN HA");
    expect(store.searchMatches).toEqual(["a", "b", "c"]);
    store.setSearch("AB C1");
    expect(store.searchMatches).toEqual(["abc123"]);
  });

  it("본문 검색 결과가 도착해도 즉시 찾은 제목 결과를 유지한다", async () => {
    const store = storeForSearch([commit("a", "정리 1"), commit("b", "Body match"), commit("c", "Other")]);
    vi.mocked(git).mockResolvedValue({ status: 0, stdout: "b\nunloaded\n", stderr: "" });
    store.setSearch("정리1");
    expect(store.searchMatches).toEqual(["a"]);
    await vi.advanceTimersByTimeAsync(350);
    expect(store.searchMatches).toEqual(["a", "b"]);
    expect(store.searchUnloaded).toBe(1);
  });

  it.each(["changes", "pullRequests"] as const)("늦은 코드 검색 결과가 %s 화면의 선택을 바꾸지 않는다", async (page) => {
    const store = storeForSearch([commit("a", "Result")]);
    store.destination = "commits"; store.setSearch("needle", "code"); store.destination = page;
    vi.mocked(git).mockResolvedValue({ status: 0, stdout: "a\n", stderr: "" });
    await vi.advanceTimersByTimeAsync(500);
    expect(store.searchMatches).toEqual(["a"]); expect(store.select).not.toHaveBeenCalled(); expect(store.destination).toBe(page);
  });
  it("공백만 입력하면 검색 결과를 비운다", () => {
    const store = storeForSearch([commit("a", "정리 1")]);
    store.setSearch("정리1");
    store.setSearch(" \t ");
    expect(store.searchMatches).toEqual([]);
    expect(store.searching).toBe(false);
  });
});
