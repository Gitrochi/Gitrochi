import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { RepoStore } from "@/entities/repo";
import { isWorkspaceDestination, repositoryDestinations, restoredDestination, workspaceDestinations, type FileChange, type Selection } from "@/entities/git";
import { settings } from "@/shared/config";
import { ipc } from "@/shared/api";

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

describe("workspace navigation", () => {
  it("lists the ten pages in the sidebar's order and rejects untrusted saved values", () => {
    expect([...workspaceDestinations]).toEqual(["home", "repository", "compare", "rebase", "code", "pullRequests", "issues", "actions", "account", "flows"]);
    for (const value of workspaceDestinations) expect(isWorkspaceDestination(value)).toBe(true);
    for (const value of [null, undefined, 3, {}, [], "", "settings", "__proto__", "Code", "../../code", "changes", "commits", "branches", "repositories", "gists", "worktrees", "assistant", "operations", "inbox", "myWork", "releases"]) expect(isWorkspaceDestination(value)).toBe(false);
  });
  it("needs a repository for every page except Home, Issues and Account", () => {
    expect([...repositoryDestinations].sort()).toEqual(["actions", "code", "compare", "flows", "pullRequests", "rebase", "repository"]);
    for (const page of workspaceDestinations) {
      const store = new RepoStore();
      expect(store.navigate(page)).toBe(!repositoryDestinations.has(page));
      expect(store.destination).toBe(repositoryDestinations.has(page) ? "home" : page);
    }
    expect(settings.set).not.toHaveBeenCalled();
  });
  it("reaches every page in an open repository and remembers the last one per repository", () => {
    const store = fixture();
    for (const page of workspaceDestinations) {
      expect(store.navigate(page)).toBe(true); expect(store.destination).toBe(page);
      expect(memory.workspaceDestinations).toEqual({ "C:/fixture/first": page });
    }
    expect(store.navigate("settings" as never)).toBe(false); expect(store.destination).toBe("flows");
  });
  it("restores the saved page per repository, falling back to the repository screen for unknown or wrongly typed values", () => {
    const cases: [unknown, string][] = [["code", "code"], ["issues", "issues"], ["flows", "flows"], ["missing-page", "repository"], ["changes", "repository"], ["commits", "repository"], ["gists", "repository"], ["settings", "repository"], [null, "repository"], [9, "repository"], [{}, "repository"], [[], "repository"], ["__proto__", "repository"]];
    for (const [saved, expected] of cases) {
      const store = fixture(); memory.workspaceDestinations = { [store.path!]: saved, "C:/fixture/second": "issues" };
      internal(store).restoreWorkspaceDestination(); expect(store.destination).toBe(expected);
    }
    const store = fixture(); memory.workspaceDestinations = { "C:/fixture/first": "code", "C:/fixture/second": "issues" };
    internal(store).restoreWorkspaceDestination(); expect(store.destination).toBe("code");
    internal(store).resetState(); expect(store.destination).toBe("home");
    store.path = "C:/fixture/second"; internal(store).restoreWorkspaceDestination(); expect(store.destination).toBe("issues");
    expect(memory.workspaceDestinations).toEqual({ "C:/fixture/first": "code", "C:/fixture/second": "issues" });
  });
  it("opens Home without a repository, even when a repository page was saved", () => {
    expect(restoredDestination("code", false)).toBe("home"); expect(restoredDestination("issues", false)).toBe("issues"); expect(restoredDestination("account", false)).toBe("account");
    expect(restoredDestination(undefined, false)).toBe("home"); expect(restoredDestination(undefined, true)).toBe("repository"); expect(restoredDestination("flows", true)).toBe("flows"); expect(restoredDestination("nope", true)).toBe("repository");
    const store = new RepoStore(); memory.workspaceDestinations = { "": "code" }; internal(store).restoreWorkspaceDestination(); expect(store.destination).toBe("home");
  });
  it("keeps every page in place during selection updates, including reconciliation on the Pull requests page", () => {
    const store = fixture(); const selections: Selection[] = [{ kind: "wip" }, { kind: "commit", sha: head }, { kind: "pullRequest", number: 7 }];
    for (const page of workspaceDestinations.filter((page) => page !== "pullRequests")) {
      store.navigate(page);
      for (const selection of selections) { store.select(selection); expect(store.destination).toBe(page); }
    }
    store.navigate("pullRequests"); store.select({ kind: "pullRequest", number: 7 });
    store.selection = { kind: "commit", sha: "c".repeat(40) }; internal(store).fixSelection(); expect(store.destination).toBe("pullRequests"); expect(store.selection).toEqual({ kind: "commit", sha: head });
  });
  it("brings a graph selection made on the Pull requests page back to the repository screen", () => {
    const store = fixture(); store.navigate("pullRequests"); store.select({ kind: "pullRequest", number: 7 }); expect(store.destination).toBe("pullRequests");
    store.select({ kind: "commit", sha: older }); expect(store.destination).toBe("repository"); expect(store.selection).toEqual({ kind: "commit", sha: older });
  });
  it("offers the way back only when the repository screen opened Pull requests or Issues", () => {
    const store = fixture(); store.navigate("repository");
    store.navigate("pullRequests"); expect(store.cameFromRepository).toBe(true);
    store.navigate("pullRequests"); expect(store.cameFromRepository).toBe(true);
    store.navigate("issues"); expect(store.cameFromRepository).toBe(false);
    store.navigate("repository"); expect(store.cameFromRepository).toBe(false);
    store.openIssue({ id: "issue-3", kind: "issue", number: 3, title: "Three", url: "", body: "", state: "open", updated: null, author: "a", unread: false });
    expect(store.destination).toBe("issues"); expect(store.cameFromRepository).toBe(true);
    for (const page of ["compare", "pullRequests", "home", "issues"] as const) { store.navigate(page); expect(store.cameFromRepository).toBe(false); }
    store.navigate("repository"); store.navigate("pullRequests"); store.select({ kind: "commit", sha: older });
    expect(store.destination).toBe("repository"); expect(store.cameFromRepository).toBe(false);
    store.navigate("issues"); internal(store).resetState(); expect(store.cameFromRepository).toBe(false);
  });
  it("clears unrelated file and diff panels when entering Pull requests", () => {
    const store = fixture(); store.selection = { kind: "commit", sha: head }; store.diffSource = { kind: "working", change: file }; store.fileInspect = { mode: "history", path: file.path, rev: null };
    store.navigate("pullRequests"); expect(store.destination).toBe("pullRequests"); expect(store.diffSource).toBeNull(); expect(store.fileInspect).toBeNull();
  });
  it("preserves an existing PR review when returning to Pull requests", () => {
    const store = fixture(); store.selection = { kind: "pullRequest", number: 7 }; const diff = { kind: "review" as const, number: 7, change: file, patch: "+fixture" }; store.diffSource = diff;
    store.navigate("code"); store.navigate("pullRequests"); expect(store.destination).toBe("pullRequests"); expect(store.diffSource).toBe(diff);
  });
  it("reveals a commit on the repository screen from any page", () => {
    const store = fixture(); store.navigate("code"); store.reveal(older);
    expect(store.destination).toBe("repository"); expect(store.scrollTarget).toBe(older); expect(store.selection).toEqual({ kind: "commit", sha: older });
  });
  it("opens working and commit diffs on the repository screen and review diffs on Pull requests", () => {
    const store = fixture(); vi.spyOn(internal(store), "loadDiff").mockImplementation(() => {});
    store.navigate("code"); store.openDiff({ kind: "working", change: file }); expect(store.destination).toBe("repository"); expect(store.selection).toEqual({ kind: "wip" }); expect(store.diffSource?.kind).toBe("working");
    store.navigate("account"); store.openDiff({ kind: "commit", sha: head, parent: older, change: file }); expect(store.destination).toBe("repository"); expect(store.diffSource?.kind).toBe("commit");
    store.navigate("issues"); store.selection = { kind: "pullRequest", number: 7 }; store.openDiff({ kind: "review", number: 7, change: file, patch: "+fixture" }); expect(store.destination).toBe("pullRequests"); expect(store.diffSource?.kind).toBe("review");
  });
  it("shows file history and blame on the repository screen", () => {
    const store = fixture(); vi.spyOn(internal(store), "loadFileInspect").mockResolvedValue();
    store.navigate("code"); store.openFileHistory(file.path); expect(store.destination).toBe("repository"); expect(store.fileInspect?.mode).toBe("history");
    store.navigate("account"); store.openBlame(file.path, head, 8); expect(store.destination).toBe("repository"); expect(store.fileInspect).toEqual({ mode: "blame", path: file.path, rev: head }); expect(store.fileInspectLine).toBe(8);
  });
  it("opens the Actions page focused on the run of a graph badge, only with a repository", () => {
    const pipeline = { id: 42, number: 7, name: "CI", title: "", ref: "main", sha: head, status: "failed" as const, url: "https://example.com/p/42", created: null, event: "push", actor: null };
    const empty = new RepoStore(); empty.openCI(pipeline); expect(empty.destination).toBe("home"); expect(empty.ciFocus).toBeNull();
    const store = fixture(); store.navigate("code"); store.openCI(pipeline); expect(store.destination).toBe("actions"); expect(store.ciFocus).toBe(42);
    internal(store).resetState(); expect(store.ciFocus).toBeNull();
  });
  it("opens commit search on the repository screen and clears documents hiding the graph", () => {
    const store = fixture(); store.navigate("code"); store.fileInspect = { mode: "history", path: file.path, rev: null }; store.diffSource = { kind: "working", change: file };
    expect(store.showSearchBar).toBe(false);
    const request = store.searchFocusRequest; store.requestSearchFocus(); expect(store.destination).toBe("repository"); expect(store.fileInspect).toBeNull(); expect(store.diffSource).toBeNull(); expect(store.searchFocusRequest).toBe(request + 1);
    // the bar shows only after the request, and closing it also ends the search
    expect(store.showSearchBar).toBe(true);
    store.searchText = "needle"; store.closeSearchBar(); expect(store.showSearchBar).toBe(false); expect(store.searchText).toBe("");
    store.requestSearchFocus(); internal(store).resetState(); expect(store.showSearchBar).toBe(false);
  });
});
