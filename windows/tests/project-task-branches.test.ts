import { afterEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() =>
  vi.stubGlobal("matchMedia", () => ({
    matches: false,
    addEventListener() {},
    removeEventListener() {},
  })),
);
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { RepoStore } from "@/entities/repo";
import { projectTaskBranches } from "@/entities/hosting";
import type { ProjectTaskReference } from "@/entities/git";
const task: ProjectTaskReference = {
  id: "TASK",
  title: "Improve search",
  url: "https://github.com/team/client/issues/7",
  number: 7,
  repository: "team/client",
  host: "github.com",
};
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});
function fixture() {
  const values = new Map<string, string>();
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
  });
  const store = new RepoStore();
  store.path = "fixture/client";
  store.target = {
    provider: "github",
    host: "github.com",
    path: "team/client",
    remote: "origin",
  };
  return store;
}
describe("local project branch references", () => {
  it("opens a prefilled branch dialog without creating a branch or association", () => {
    const store = fixture(),
      run = vi.spyOn(store, "run").mockResolvedValue(true);
    store.requestNewBranch("HEAD", "main", "feature/7-improve-search", task);
    expect(store.sheet).toMatchObject({
      kind: "newBranch",
      suggestedName: "feature/7-improve-search",
      projectTask: task,
    });
    expect(run).not.toHaveBeenCalled();
    expect(
      projectTaskBranches(
        "fixture/client",
        "TASK",
        "team/client",
        "github.com",
      ),
    ).toEqual([]);
  });
  it("records the task only after successful branch creation in the captured repository", async () => {
    const store = fixture();
    vi.spyOn(store, "run").mockResolvedValue(true);
    await store.createBranch("feature/7-improve-search", "HEAD", true, task);
    expect(
      projectTaskBranches(
        "fixture/client",
        "TASK",
        "team/client",
        "github.com",
      ),
    ).toEqual(["feature/7-improve-search"]);
    expect(
      projectTaskBranches("fixture/other", "TASK", "team/client", "github.com"),
    ).toEqual([]);
    expect(
      projectTaskBranches(
        "fixture/client",
        "TASK",
        "team/client",
        "enterprise.test",
      ),
    ).toEqual([]);
  });
  it("does not record failed branches or stale repository contexts", async () => {
    const store = fixture(),
      run = vi.spyOn(store, "run").mockResolvedValue(false);
    await store.createBranch("feature/failed", "HEAD", true, task);
    expect(
      projectTaskBranches(
        "fixture/client",
        "TASK",
        "team/client",
        "github.com",
      ),
    ).toEqual([]);
    run.mockImplementation(async () => {
      store.path = "fixture/other";
      return true;
    });
    await store.createBranch("feature/stale", "HEAD", true, task);
    expect(
      projectTaskBranches(
        "fixture/client",
        "TASK",
        "team/client",
        "github.com",
      ),
    ).toEqual([]);
  });
});
