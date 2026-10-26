import { afterEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { parseConflict, type FileChange, type FileHistoryEntry } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";

const text = (label: string) => `<<<<<<< HEAD\n${label}\n=======\nother\n>>>>>>> topic\n`;
const change = (path: string): FileChange => ({ path, oldPath: null, kind: "conflicted", staged: false });
const entry = (path: string): FileHistoryEntry => ({ path, commit: { id: "same-sha", parents: ["parent"], author: "", email: "", date: 0, subject: "" } });
const internals = (store: RepoStore) => store as unknown as { g(args: string[]): Promise<{ stdout: string }> };
afterEach(() => vi.restoreAllMocks());

describe("충돌 파일 선택의 수명", () => {
  it("현재 파일의 선택은 저장하고 스테이지한 뒤 닫는다", async () => {
    const store = new RepoStore();
    store.path = "C:/repo";
    store.conflictPath = "current.txt";
    store.conflictDoc = parseConflict(text("chosen"));
    store.chooseConflict(0, { kind: "ours" });
    vi.spyOn(ipc, "readText").mockResolvedValue(text("chosen"));
    const write = vi.spyOn(ipc, "writeText").mockResolvedValue(undefined);
    const stage = vi.spyOn(store, "run").mockResolvedValue(true);
    await store.saveConflictResolution(change("current.txt"));
    expect(write).toHaveBeenCalledWith("C:/repo/current.txt", "chosen\n");
    expect(stage).toHaveBeenCalledWith(expect.any(String), ["add", "--", "current.txt"]);
    expect(store.conflictDoc).toBeNull();
  });

  it("먼저 선택한 파일의 늦은 응답이 새 선택을 덮지 않는다", async () => {
    const store = new RepoStore();
    store.path = "C:/repo";
    let finish!: (text: string) => void;
    vi.spyOn(ipc, "readText").mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; })).mockResolvedValueOnce(text("new"));
    const old = store.loadConflict("old.txt");
    await store.loadConflict("new.txt");
    finish(text("old"));
    await old;
    expect(store.conflictPath).toBe("new.txt");
    expect(store.conflictDoc?.blocks[0].ours).toEqual(["new"]);
  });

  it("닫은 후 도착한 충돌 파일은 다시 열지 않는다", async () => {
    const store = new RepoStore();
    store.path = "C:/repo";
    let finish!: (text: string) => void;
    vi.spyOn(ipc, "readText").mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    const loading = store.loadConflict("old.txt");
    store.closeConflict();
    finish(text("old"));
    await loading;
    expect(store.conflictDoc).toBeNull();
    expect(store.conflictPath).toBeNull();
  });

  it("다른 파일의 선택 결과를 현재 파일에 쓰지 않는다", async () => {
    const store = new RepoStore();
    store.path = "C:/repo";
    store.conflictPath = "old.txt";
    store.conflictDoc = parseConflict(text("old"));
    store.chooseConflict(0, { kind: "ours" });
    const write = vi.spyOn(ipc, "writeText").mockResolvedValue(undefined);
    vi.spyOn(store, "run").mockResolvedValue(true);
    await store.saveConflictResolution(change("new.txt"));
    expect(write).not.toHaveBeenCalled();
  });
  it("편집기 밖에서 원본이 바뀌면 결과를 덮어쓰지 않는다", async () => {
    const store = new RepoStore(); store.path = "C:/repo"; store.conflictPath = "current.txt"; store.conflictDoc = parseConflict(text("old"));
    store.chooseConflict(0, { kind: "ours" });
    vi.spyOn(ipc, "readText").mockResolvedValue(text("external edit")); const write = vi.spyOn(ipc, "writeText").mockResolvedValue(undefined);
    await store.saveConflictResolution(change("current.txt")); expect(write).not.toHaveBeenCalled(); expect(store.errorMessage).toContain("changed outside");
  });
  it("직접 편집 결과에 미해결 표식이 있으면 저장하지 않는다", async () => {
    const store = new RepoStore(); store.path = "C:/repo"; store.conflictPath = "current.txt"; store.conflictDoc = parseConflict(text("old"));
    const write = vi.spyOn(ipc, "writeText").mockResolvedValue(undefined);
    await store.saveConflictResolution(change("current.txt"), text("unresolved")); expect(write).not.toHaveBeenCalled(); expect(store.errorMessage).toContain("every conflict marker");
  });
});

describe("파일 히스토리 선택의 수명", () => {
  it("같은 커밋에서 바뀐 다른 파일을 열면 이전 선택과 diff를 지운다", () => {
    const store = new RepoStore();
    store.path = "C:/repo";
    store.fileInspect = { mode: "history", path: "old.txt", rev: null };
    store.fileHistorySelected = "same-sha";
    store.fileHistoryDiff = { lines: [], isBinary: false, truncated: false, header: ["old"], hunks: [] };
    vi.spyOn(internals(store), "g").mockResolvedValue({ stdout: "" });
    store.openFileHistory("new.txt");
    expect(store.fileHistorySelected).toBeNull();
    expect(store.fileHistoryDiff).toBeNull();
  });

  it("이전 파일의 실패가 같은 커밋의 새 파일 diff를 덮지 않는다", async () => {
    const store = new RepoStore();
    store.path = "C:/repo";
    let reject!: (error: Error) => void;
    vi.spyOn(internals(store), "g")
      .mockImplementationOnce(() => new Promise((_resolve, fail) => { reject = fail; }))
      .mockResolvedValueOnce({ stdout: "diff --git a/new.txt b/new.txt\n--- a/new.txt\n+++ b/new.txt\n@@ -1 +1 @@\n-old\n+new\n" });
    const loading = store.selectHistory(entry("old.txt"));
    await store.selectHistory(entry("new.txt"));
    reject(new Error("old file failed"));
    await loading;
    expect(store.fileHistoryDiff?.error).toBeUndefined();
    expect(store.fileHistoryDiff?.lines.at(-1)?.text).toBe("new");
  });

  it("히스토리를 닫은 뒤 실패 응답이 diff를 다시 만들지 않는다", async () => {
    const store = new RepoStore();
    store.path = "C:/repo";
    let reject!: (error: Error) => void;
    vi.spyOn(internals(store), "g").mockImplementation(() => new Promise((_resolve, fail) => { reject = fail; }));
    const loading = store.selectHistory(entry("old.txt"));
    store.closeFileInspect();
    reject(new Error("old file failed"));
    await loading;
    expect(store.fileHistoryDiff).toBeNull();
  });
});
