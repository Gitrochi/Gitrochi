import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppLaunch } from "@/shared/api";

const state = vi.hoisted(() => {
  const store = {
    id: "repo-tab", path: "C:/repo",
    status: { unstaged: [{ path: "src/a.ts", oldPath: null }], staged: [] },
    detail: {}, detailFiles: [{ path: "src/a.ts", oldPath: null }],
    selection: { kind: "commit", sha: "a".repeat(40) },
    openBlame: vi.fn(), openFileHistory: vi.fn(), openDiff: vi.fn(), revealPath: vi.fn(),
    closeFileInspect: vi.fn(), closeDiff: vi.fn(), select: vi.fn(), reveal: vi.fn(),
    openStructureGraph: vi.fn(), openAffectedGraph: vi.fn(), fail: vi.fn(),
  };
  const workspace = { active: store, tabs: [store], openInNewTab: vi.fn(), select: vi.fn(), newTab: vi.fn(() => store) };
  return { store, workspace, take: vi.fn(), listen: vi.fn() };
});

vi.mock("@/entities/workspace", () => ({ workspace: state.workspace }));
vi.mock("@/shared/api", () => ({ ipc: { takeAppLaunches: state.take, onAppLaunch: state.listen } }));
vi.mock("@/shared/config", () => ({ samePath: (a: string, b: string) => a?.replaceAll("\\", "/").toLowerCase() === b?.replaceAll("\\", "/").toLowerCase() }));
vi.mock("@/shared/i18n", () => ({ t: (s: string) => s }));

import { applyAppLaunch, startAppLaunches } from "../src/app/lib/app-launch";

const route = (change: Partial<AppLaunch> = {}): AppLaunch => ({ repo: "C:\\repo", file: null, line: null, view: null, commit: null, ...change });

beforeEach(() => {
  vi.clearAllMocks();
  state.take.mockReset();
  state.listen.mockReset();
  vi.stubGlobal("window", { addEventListener: vi.fn() });
});

describe("CLI 와 브라우저 앱 탐색", () => {
  it("reveals repository, folder and file links without opening history", async () => {
    for (const file of [null, "src/한글 & folder", "src/a.ts"]) {
      await applyAppLaunch(route({ view: "finder", file }));
    }
    expect(state.store.revealPath.mock.calls).toEqual([[""], ["src/한글 & folder"], ["src/a.ts"]]);
    expect(state.store.openFileHistory).not.toHaveBeenCalled();
    expect(state.store.openStructureGraph).not.toHaveBeenCalled();
    expect(state.store.openDiff).not.toHaveBeenCalled();
  });
  it("기존 저장소 탭을 선택하고 요청한 파일의 실제 줄을 연다", async () => {
    await applyAppLaunch(route({ file: "src/a.ts", line: 27 }));
    expect(state.workspace.openInNewTab).toHaveBeenCalledWith("C:\\repo");
    expect(state.workspace.select).toHaveBeenCalledWith("repo-tab");
    expect(state.store.openBlame).toHaveBeenCalledWith("src/a.ts", null, 27);
    expect(state.store.openFileHistory).not.toHaveBeenCalled();
  });
  it("변경한 파일의 diff 와 파일 히스토리를 구분한다", async () => {
    await applyAppLaunch(route({ file: "src/a.ts", view: "diff" }));
    expect(state.store.openDiff).toHaveBeenCalledWith({ kind: "working", change: state.store.status.unstaged[0] });
    await applyAppLaunch(route({ file: "deleted.ts", view: "diff" }));
    expect(state.store.openFileHistory).toHaveBeenCalledWith("deleted.ts");
  });
  it("정밀 참조와 영향 범위는 앱 메뉴와 같은 분석을 사용한다", async () => {
    await applyAppLaunch(route({ view: "precise" }));
    expect(state.store.openStructureGraph).toHaveBeenCalledWith("files", true);
    await applyAppLaunch(route({ view: "affected" }));
    expect(state.store.openAffectedGraph).toHaveBeenCalledOnce();
  });
  it("근거 커밋 링크는 해당 커밋과 파일 diff 를 연다", async () => {
    const commit = "a".repeat(40);
    await applyAppLaunch(route({ file: "src/a.ts", commit }));
    expect(state.store.select).toHaveBeenCalledWith({ kind: "commit", sha: commit });
    expect(state.store.openDiff).toHaveBeenCalledWith({ kind: "commit", sha: commit, change: state.store.detailFiles[0], parent: null });
  });
  it("콜드 스타트 큐와 실행 중 추가된 링크를 한 번씩 처리한다", async () => {
    let notify = () => {};
    state.listen.mockImplementation(async (fn: () => void) => { notify = fn; return vi.fn(); });
    state.take.mockResolvedValueOnce([{ Ok: route({ file: "a.ts", line: 2 }) }]).mockResolvedValueOnce([{ Ok: route({ file: "b.ts", line: 3 }) }]);
    await startAppLaunches();
    expect(state.store.openBlame).toHaveBeenNthCalledWith(1, "a.ts", null, 2);
    notify();
    await vi.waitFor(() => expect(state.store.openBlame).toHaveBeenNthCalledWith(2, "b.ts", null, 3));
    expect(state.store.openBlame).toHaveBeenCalledTimes(2);
  });
  it("거부된 링크는 오류를 표시하고 그 뒤의 정상 링크도 연다", async () => {
    state.listen.mockResolvedValue(vi.fn());
    state.take.mockResolvedValue([{ Err: "Invalid link" }, { Ok: route({ file: "a.ts" }) }]);
    await startAppLaunches();
    expect(state.store.fail).toHaveBeenCalledOnce();
    expect(state.store.openFileHistory).toHaveBeenCalledWith("a.ts");
  });
});
