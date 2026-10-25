import { afterEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));

import { gitch, type GraphReview } from "@/entities/gitch";
import { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";

const result = (): GraphReview => ({
  schemaVersion: 1, tool: "gitch graph review", scope: "staged", stamp: "original", snapshot: "tree", headSha: "head", branch: "feature", stale: false,
  changed: [{ path: "src/core.ts", status: "M", analyzed: true }], direct: [], indirect: [], tests: [],
  coverage: { changed: 1, analyzed: 1, unsupported: 0 }, limitations: [],
});
const storeForReview = () => {
  const store = new RepoStore();
  store.path = "C:/repo";
  store.status.staged = [{ path: "src/core.ts", oldPath: null, staged: true, kind: "modified" }];
  return store;
};
const internals = (store: RepoStore) => store as unknown as { statusGeneration: number; verifyCommitImpact(): Promise<void> };

afterEach(() => vi.restoreAllMocks());

describe("스테이지 분석의 수명과 최신 결과", () => {
  it("분석 도중 재스테이지되면 최신 결과라고 표시하지 않는다", async () => {
    const store = storeForReview();
    vi.spyOn(gitch, "commitReview").mockResolvedValue(result());
    vi.spyOn(gitch, "commitReviewStamp").mockResolvedValue("changed");
    await store.analyzeCommitImpact();
    expect(store.commitImpact?.kind).toBe("done");
    expect(store.commitImpactStale).toBe(true);
    expect(store.busy).toBeNull();
  });

  it("저장소를 닫은 뒤 늦게 도착한 분석은 버린다", async () => {
    const store = storeForReview();
    let finish!: (data: GraphReview) => void;
    vi.spyOn(gitch, "commitReview").mockImplementation(() => new Promise((resolve) => { finish = resolve; }));
    const stamp = vi.spyOn(gitch, "commitReviewStamp").mockResolvedValue("original");
    const loading = store.analyzeCommitImpact();
    expect(store.commitImpact?.kind).toBe("running");
    store.close();
    finish(result());
    await loading;
    expect(store.commitImpact).toBeNull();
    expect(store.commitImpactVerifying).toBe(false);
    expect(stamp).not.toHaveBeenCalled();
  });

  it("같은 파일 수·이름이라도 새로고침 뒤 stamp를 확인하고, 내용이 같으면 재사용한다", async () => {
    const store = storeForReview();
    vi.spyOn(gitch, "commitReview").mockResolvedValue(result());
    const stamp = vi.spyOn(gitch, "commitReviewStamp").mockResolvedValue("original");
    await store.analyzeCommitImpact();
    expect(store.commitImpactStale).toBe(false);
    internals(store).statusGeneration++;
    expect(store.commitImpactStale).toBe(true);
    await internals(store).verifyCommitImpact();
    expect(store.commitImpactStale).toBe(false);
    stamp.mockResolvedValue("same-file-new-content");
    internals(store).statusGeneration++;
    await internals(store).verifyCommitImpact();
    expect(store.commitImpactStale).toBe(true);
  });

  it("그래프를 만들기 전에 바뀐 스냅샷은 열지 않는다", async () => {
    const store = storeForReview();
    vi.spyOn(gitch, "commitReview").mockResolvedValue(result());
    const stamp = vi.spyOn(gitch, "commitReviewStamp").mockResolvedValue("original");
    const draw = vi.spyOn(gitch, "commitReviewGraph");
    const open = vi.spyOn(ipc, "openHtml").mockResolvedValue(undefined);
    await store.analyzeCommitImpact();
    stamp.mockResolvedValue("new");
    await store.openCommitImpactGraph();
    expect(draw).not.toHaveBeenCalled();
    expect(open).not.toHaveBeenCalled();
    expect(store.commitImpactStale).toBe(true);
    expect(store.graphJob).toBeNull();
  });

  it("그래프를 만드는 동안 바뀌어도 다른 범위의 결과를 열지 않는다", async () => {
    const store = storeForReview();
    vi.spyOn(gitch, "commitReview").mockResolvedValue(result());
    const stamp = vi.spyOn(gitch, "commitReviewStamp").mockResolvedValueOnce("original").mockResolvedValueOnce("original").mockResolvedValueOnce("new");
    vi.spyOn(gitch, "commitReviewGraph").mockResolvedValue({ file: "C:/temp/staged.html", nodes: 1, hint: null });
    const open = vi.spyOn(ipc, "openHtml").mockResolvedValue(undefined);
    await store.analyzeCommitImpact();
    await store.openCommitImpactGraph();
    expect(stamp).toHaveBeenCalledTimes(3);
    expect(open).not.toHaveBeenCalled();
    expect(store.commitImpactStale).toBe(true);
  });
});
