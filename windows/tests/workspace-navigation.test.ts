import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { RepoStore } from "@/entities/repo";
import { isWorkspaceDestination, isRepositorySection, repositorySections, repositoryDestinations, workspaceDestinations, workspaceLocation, type FileChange, type Selection, type WorkspaceDestination } from "@/entities/git";
import { settings } from "@/shared/config";
import { ipc } from "@/shared/api";

const expectPage = (store: RepoStore, page: WorkspaceDestination) => { expect(store.destination).toBe(isRepositorySection(page) ? "repository" : page); if (isRepositorySection(page)) expect(store.repositorySection).toBe(page); };
const head = "a".repeat(40), older = "b".repeat(40);
const file: FileChange = { path: "src/fixture.ts", oldPath: null, kind: "modified", staged: false };
let memory: Record<string, unknown>;
const internal = (store: RepoStore) => store as unknown as { restoreWorkspaceDestination(): void; resetState(): void; fixSelection(): void; loadDiff(keepCurrent: boolean): void; loadFileInspect(): Promise<void>; g(args: string[]): Promise<{ stdout: string; stderr: string; status: number }> };
const fixture = () => {
  const store = new RepoStore(); store.path = "C:/fixture/first"; store.headHash = head; store.headBranch = "main"; store.commitIndex.set(head, 0); store.commitIndex.set(older, 1);
  vi.spyOn(internal(store), "g").mockResolvedValue({ stdout: "", stderr: "", status: 0 });
  return store;
};
beforeEach(() => {
  memory = {};
  vi.spyOn(settings, "get").mockImplementation(<T>(key: string, fallback: T): T => (memory[key] ?? fallback) as T);
  vi.spyOn(settings, "set").mockImplementation((key, value) => { memory[key] = value; });
  vi.spyOn(ipc, "writeText").mockImplementation(async () => { throw new Error("Navigation tests must not write files"); });
  vi.spyOn(ipc, "run").mockImplementation(async () => { throw new Error("Navigation tests must not start processes"); });
});
afterEach(() => { expect(ipc.writeText).not.toHaveBeenCalled(); expect(ipc.run).not.toHaveBeenCalled(); vi.restoreAllMocks(); });

describe("workspace menu navigation", () => {
  it("recognizes every unique menu and rejects untrusted saved values", () => {
    expect(workspaceDestinations).toHaveLength(22); expect(new Set(workspaceDestinations).size).toBe(22);
    for (const value of workspaceDestinations) expect(isWorkspaceDestination(value)).toBe(true);
    for (const value of [null, undefined, 3, {}, [], "", "settings", "__proto__", "Code", "../../code"]) expect(isWorkspaceDestination(value)).toBe(false);
  });
  it("disables local repository pages without changing history while keeping global menus available", () => {
    for (const page of workspaceDestinations) {
      const store = new RepoStore();
      expect(store.navigate(page, false)).toBe(!repositoryDestinations.has(page));
      if (repositoryDestinations.has(page)) { expect(store.destination).toBe("home"); expect(store.navigationTrail).toEqual([workspaceLocation("home")]); }
      else expectPage(store, page);
    }
    expect(settings.set).not.toHaveBeenCalled();
  });
  it("keeps all routes reachable, with six tools inside one repository in an open repository", () => {
    const store = fixture(); for (const page of workspaceDestinations) { expect(store.navigate(page, false)).toBe(true); expectPage(store, page); }
  });
  it("keeps every non-document page in place during background selection updates", () => {
    const store = fixture(); const selections: Selection[] = [{ kind: "wip" }, { kind: "commit", sha: head }, { kind: "pullRequest", number: 7 }, null].filter((value): value is Selection => value !== null);
    for (const page of workspaceDestinations.filter((page) => !["repository", "changes", "commits", "pullRequests"].includes(page))) {
      store.navigate(page, false); const trail = [...store.navigationTrail];
      for (const selection of selections) { store.select(selection); expectPage(store, page); }
      store.syncWorkspaceSelection(null); expect(store.navigationTrail).toEqual(trail);
    }
  });
  it("does not let automatic selection reconciliation take over Code or hosting pages", () => {
    const store = fixture();
    for (const page of ["code", "gists", "inbox", "myWork"] as WorkspaceDestination[]) {
      store.navigate(page, false); store.selection = { kind: "commit", sha: "c".repeat(40) }; internal(store).fixSelection(); expectPage(store, page); expect(store.selection).toEqual({ kind: "commit", sha: head });
    }
  });
  it("opens Changes with working-tree selection and clears an unrelated commit diff", () => {
    const store = fixture(); store.selection = { kind: "commit", sha: older }; store.diffSource = { kind: "commit", sha: older, parent: null, change: file };
    expect(store.navigate("changes")).toBe(true); expectPage(store, "changes"); expect(store.selection).toEqual({ kind: "wip" }); expect(store.diffSource).toBeNull();
  });
  it("opens Commits at HEAD when leaving working-tree or PR selection", () => {
    const store = fixture();
    for (const selection of [{ kind: "wip" }, { kind: "pullRequest", number: 7 }] as Selection[]) {
      store.selection = selection; store.diffSource = { kind: "working", change: file }; store.navigate("commits");
      expectPage(store, "commits"); expect(store.selection).toEqual({ kind: "commit", sha: head }); expect(store.diffSource).toBeNull();
    }
  });
  it("retains an explicitly selected commit when entering its menu again", () => {
    const store = fixture(); store.selection = { kind: "commit", sha: older }; const diff = { kind: "commit" as const, sha: older, parent: null, change: file }; store.diffSource = diff;
    store.navigate("code"); store.navigate("commits"); expect(store.selection).toEqual({ kind: "commit", sha: older }); expect(store.diffSource).toBe(diff);
  });
  it("clears unrelated file and diff panels when entering Pull requests", () => {
    const store = fixture(); store.selection = { kind: "commit", sha: head }; store.diffSource = { kind: "working", change: file }; store.fileInspect = { mode: "history", path: file.path, rev: null };
    store.navigate("pullRequests"); expect(store.destination).toBe("pullRequests"); expect(store.diffSource).toBeNull(); expect(store.fileInspect).toBeNull();
  });
  it("preserves an existing PR review when returning to Pull requests", () => {
    const store = fixture(); store.selection = { kind: "pullRequest", number: 7 }; const diff = { kind: "review" as const, number: 7, change: file, patch: "+fixture" }; store.diffSource = diff;
    store.navigate("code"); store.navigate("pullRequests"); expect(store.destination).toBe("pullRequests"); expect(store.diffSource).toBe(diff);
  });
  it("syncs explicit selections between the three document menus and graph reveal leaves utility pages", () => {
    const store = fixture(); store.navigate("changes"); store.select({ kind: "commit", sha: older }); expectPage(store, "commits"); store.select({ kind: "pullRequest", number: 7 }); expect(store.destination).toBe("pullRequests"); store.select({ kind: "wip" }); expectPage(store, "changes");
    store.navigate("branches"); store.reveal(older); expectPage(store, "commits"); expect(store.scrollTarget).toBe(older); expect(store.selection).toEqual({ kind: "commit", sha: older });
  });
  it("opens an explicitly requested working, commit or PR diff in its matching document menu", () => {
    const store = fixture(); vi.spyOn(internal(store), "loadDiff").mockImplementation(() => {});
    store.navigate("code"); store.openDiff({ kind: "working", change: file }); expectPage(store, "changes"); expect(store.diffSource?.kind).toBe("working");
    store.navigate("gists"); store.openDiff({ kind: "commit", sha: head, parent: older, change: file }); expectPage(store, "commits"); expect(store.diffSource?.kind).toBe("commit");
    store.navigate("issues"); store.selection = { kind: "pullRequest", number: 7 }; store.openDiff({ kind: "review", number: 7, change: file, patch: "+fixture" }); expect(store.destination).toBe("pullRequests"); expect(store.diffSource?.kind).toBe("review");
  });
  it("reveals explicit file history and blame requests while retaining an active local document menu", () => {
    const store = fixture(); vi.spyOn(internal(store), "loadFileInspect").mockResolvedValue();
    store.navigate("code"); store.openFileHistory(file.path); expectPage(store, "commits"); expect(store.fileInspect?.mode).toBe("history");
    store.navigate("organizations"); store.openBlame(file.path, head, 8); expectPage(store, "commits"); expect(store.fileInspect).toEqual({ mode: "blame", path: file.path, rev: head }); expect(store.fileInspectLine).toBe(8);
    store.navigate("changes"); store.openBlame(file.path); expectPage(store, "changes");
  });
  it("opens commit search from utility pages and clears documents hiding the graph", () => {
    const store = fixture(); store.navigate("code"); store.fileInspect = { mode: "history", path: file.path, rev: null }; store.diffSource = { kind: "working", change: file };
    const request = store.searchFocusRequest; store.requestSearchFocus(); expectPage(store, "commits"); expect(store.fileInspect).toBeNull(); expect(store.diffSource).toBeNull(); expect(store.searchFocusRequest).toBe(request + 1);
  });
  it("supports back and forward without appending duplicate history, and ignores out-of-bounds moves", () => {
    const store = fixture(); for (const page of ["code", "branches", "rebase"] as WorkspaceDestination[]) store.navigate(page, false);
    const trail = [...store.navigationTrail]; store.moveWorkspaceHistory(-1); expectPage(store, "branches"); store.moveWorkspaceHistory(1); expectPage(store, "rebase"); store.moveWorkspaceHistory(10); expectPage(store, "rebase"); store.moveWorkspaceHistory(-10); expectPage(store, "rebase"); expect(store.navigationTrail).toEqual(trail);
  });
  it("drops forward entries after going back and opening a different page", () => {
    const store = fixture(); store.navigate("code"); store.navigate("branches"); store.navigate("rebase"); store.moveWorkspaceHistory(-1); store.navigate("issues"); expect(store.navigationTrail).toEqual([workspaceLocation("home"), workspaceLocation("code"), workspaceLocation("branches"), workspaceLocation("issues", "branches")]); expect(store.navigationPosition).toBe(3); store.moveWorkspaceHistory(1); expect(store.destination).toBe("issues");
  });
  it("does not duplicate the current page and bounds a long session to 40 entries", () => {
    const store = fixture(); store.navigate("code"); store.navigate("code"); expect(store.navigationTrail).toEqual([workspaceLocation("home"), workspaceLocation("code")]);
    for (let i = 0; i < 60; i++) store.navigate(i % 2 ? "branches" : "rebase"); expect(store.navigationTrail).toHaveLength(40); expect(store.navigationPosition).toBe(39); expect(store.navigationTrail.at(-1)).toEqual(workspaceLocation(store.destination, store.repositorySection));
  });
  it("restores valid pages per repository with a fresh history", () => {
    const store = fixture(); memory.workspaceDestinations = { "C:/fixture/first": "code", "C:/fixture/second": "issues" };
    store.navigate("branches"); memory.workspaceDestinations = { "C:/fixture/first": "code", "C:/fixture/second": "issues" }; internal(store).restoreWorkspaceDestination(); expectPage(store, "code"); expect(store.navigationTrail).toEqual([workspaceLocation("code")]); expect(store.navigationPosition).toBe(0);
    internal(store).resetState(); store.path = "C:/fixture/second"; internal(store).restoreWorkspaceDestination(); expect(store.destination).toBe("issues"); expect(store.navigationTrail).toEqual([workspaceLocation("issues")]);
  });
  it("uses a safe document fallback for unknown or incorrectly typed saved pages", () => {
    for (const saved of ["missing-page", "settings", null, 9, {}, [], "__proto__"]) {
      const store = fixture(); store.selection = { kind: "commit", sha: head }; memory.workspaceRepositorySections = {}; memory.workspaceDestinations = { [store.path!]: saved }; internal(store).restoreWorkspaceDestination(); expectPage(store, "commits"); expect(store.navigationTrail).toEqual([workspaceLocation("commits")]);
    }
    const store = fixture(); store.selection = { kind: "wip" }; memory.workspaceRepositorySections = {}; memory.workspaceDestinations = { [store.path!]: "invalid" }; internal(store).restoreWorkspaceDestination(); expectPage(store, "changes");
  });
  it("opens the consolidated repository at its remembered section and keeps pinning independent of navigation", () => {
    const store = fixture(); expect(store.pinnedRepositoryPages).toEqual([]);
    store.selectRepositorySection("compare", false); store.navigate("issues", false); store.navigate("repository", false); expectPage(store, "compare");
    const before = [...store.navigationTrail]; store.toggleRepositoryPagePin("compare"); store.toggleRepositoryPagePin("changes");
    expect(store.pinnedRepositoryPages).toEqual(["changes", "compare"]); expect(store.navigationTrail).toEqual(before);
    const other = fixture(); expect(other.pinnedRepositoryPages).toEqual(["changes", "compare"]);
    other.toggleRepositoryPagePin("compare"); expect(store.isRepositoryPagePinned("compare")).toBe(false); expectPage(store, "compare");
    memory.pinnedRepositoryPages = ["unknown", "code", "code", "__proto__", "rebase"]; expect(store.pinnedRepositoryPages).toEqual(["rebase", "code"]);
    memory.pinnedRepositoryPages = "changes"; expect(store.pinnedRepositoryPages).toEqual([]);
    expect(repositorySections).toHaveLength(6);
  });
  it("restores internal sections per repository and migrates legacy section routes", () => {
    const store = fixture(); memory.workspaceDestinations = { [store.path!]: "repository", "C:/fixture/second": "repository" };
    memory.workspaceRepositorySections = { [store.path!]: "compare", "C:/fixture/second": "rebase" };
    internal(store).restoreWorkspaceDestination(); expectPage(store, "compare");
    internal(store).resetState(); store.path = "C:/fixture/second"; internal(store).restoreWorkspaceDestination(); expectPage(store, "rebase");
    memory.workspaceDestinations = { [store.path!]: "code" }; internal(store).restoreWorkspaceDestination(); expectPage(store, "code");
    expect(memory.workspaceDestinations).toEqual({ [store.path!]: "repository" }); expect(memory.workspaceRepositorySections).toEqual({ "C:/fixture/first": "compare", [store.path!]: "code" });
  });

});
