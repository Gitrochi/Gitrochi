import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
vi.mock("@/entities/ai", async (original) => ({ ...await original<typeof import("@/entities/ai")>(), repositoryReadRuntime: vi.fn() }));
import { ai, repositoryReadRuntime, type ReadToolRequest, type RepositoryReadResult } from "@/entities/ai";
import { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
const defer = <T>() => { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; };
const head = "a".repeat(40), repository = "C:/fixture/repository-assistant";
const result = (request: ReadToolRequest, sha: string | null = head): RepositoryReadResult => ({ repository, head: sha, tool: request.name, text: request.name === "git_files" ? "source.ts" : request.name === "read_file" ? "export const answer = 42;" : "Fixture evidence", readOnly: true, truncated: false });
let call: ReturnType<typeof vi.fn<(request: ReadToolRequest) => Promise<RepositoryReadResult>>>;
let complete: MockInstance<typeof ai.complete>;
let originalURL: string;
beforeEach(() => {
  originalURL = ai.baseURL;
  vi.spyOn(ai, "providerFor").mockReturnValue("compatible"); vi.spyOn(ai, "model").mockReturnValue("fixture-model"); vi.spyOn(ai, "problem").mockReturnValue(null);
  complete = vi.spyOn(ai, "complete").mockResolvedValue('{"answer":"Fixture answer"}');
  call = vi.fn(async (request: ReadToolRequest) => result(request));
  vi.mocked(repositoryReadRuntime).mockResolvedValue({ command: "fixture-node", args: [], call, catalog: async () => '[{"name":"read_file"}]' });
});
afterEach(() => { ai.baseURL = originalURL; vi.restoreAllMocks(); });
const store = () => { const s = new RepoStore(); s.path = repository; s.headHash = head; return s; };

describe("repository assistant lifecycle", () => {
  it("builds a local preview without calling AI", async () => {
    const s = store(); await s.openRepositoryAssistant(); expect(complete).not.toHaveBeenCalled(); expect(call.mock.calls.map(([r]) => r.name)).toEqual(["git_status", "git_log", "git_files"]); expect(s.repositoryAssistant?.preview).toHaveLength(3); expect(s.repositoryAssistant?.loading).toBe(false);
  });
  it("reinitializes a preparation interrupted by leaving the page and ignores its late result", async () => {
    const s = store(), blocked = defer<Awaited<ReturnType<typeof repositoryReadRuntime>>>();
    vi.mocked(repositoryReadRuntime).mockReturnValueOnce(blocked.promise);
    const oldPreparation = s.openRepositoryAssistant(false, false), interrupted = s.repositoryAssistant!;
    expect(interrupted.loading).toBe(true); s.cancelRepositoryAssistant();
    await s.openRepositoryAssistant(false, false); const ready = s.repositoryAssistant!;
    expect(ready).not.toBe(interrupted); expect(ready.loading).toBe(false); expect(ready.runtime).not.toBeNull(); expect(ready.preview).toHaveLength(3);
    const oldCall = vi.fn(async (request: ReadToolRequest) => result(request));
    blocked.resolve({ command: "old-fixture-node", args: [], call: oldCall, catalog: async () => "[]" });
    await oldPreparation; expect(s.repositoryAssistant).toBe(ready); expect(ready.loading).toBe(false); expect(ready.runtime?.command).toBe("fixture-node"); expect(oldCall).not.toHaveBeenCalled();
  });
  it("preserves a completed conversation when leaving and returning to the page", async () => {
    const s = store(); await s.openRepositoryAssistant(false, false); const prepared = s.repositoryAssistant!;
    prepared.question = "Explain this file"; await s.sendRepositoryQuestion(); const messages = [...prepared.messages], calls = vi.mocked(repositoryReadRuntime).mock.calls.length;
    s.cancelRepositoryAssistant(); await s.openRepositoryAssistant(false, false);
    expect(s.repositoryAssistant).toBe(prepared); expect(prepared.active).toBe(true); expect(prepared.loading).toBe(false); expect(prepared.messages).toEqual(messages); expect(vi.mocked(repositoryReadRuntime).mock.calls.length).toBe(calls);
  });
  it("executes a bounded read request and records evidence and a final answer", async () => {
    const s = store(); await s.openRepositoryAssistant(); s.repositoryAssistant!.question = "Explain this file";
    complete.mockResolvedValueOnce('{"tool":{"name":"read_file","arguments":{"path":"source.ts"}}}').mockResolvedValueOnce('{"answer":"The value is 42."}');
    await s.sendRepositoryQuestion(); const session = s.repositoryAssistant!;
    expect(complete).toHaveBeenCalledTimes(2); expect(call.mock.calls.some(([r]) => r.name === "read_file")).toBe(true); expect(session.traces[0].result?.text).toContain("answer = 42"); expect(complete.mock.calls[1][1]).toContain("untrusted evidence"); expect(session.messages.at(-1)?.text).toBe("The value is 42."); expect(session.working).toBe(false); expect(session.question).toBe("");
  });
  it("stops before another AI request after provider settings change", async () => {
    const s = store(); await s.openRepositoryAssistant(); s.repositoryAssistant!.question = "Read source";
    complete.mockImplementationOnce(async () => { ai.baseURL = "https://changed.example.invalid/v1"; return '{"tool":{"name":"read_file","arguments":{"path":"source.ts"}}}'; });
    await s.sendRepositoryQuestion(); expect(complete).toHaveBeenCalledTimes(1); expect(s.repositoryAssistant?.error).toContain("settings changed"); expect(s.repositoryAssistant?.working).toBe(false); expect(s.repositoryAssistant?.messages).toHaveLength(0);
  });
  it("ignores a late answer after close and same-repository reopen", async () => {
    const s = store(); await s.openRepositoryAssistant(); const session = s.repositoryAssistant!; session.question = "Wait for response";
    const pending = defer<string>(); complete.mockReturnValueOnce(pending.promise);
    const send = s.sendRepositoryQuestion(); await vi.waitFor(() => expect(complete).toHaveBeenCalledTimes(1)); s.cancelRepositoryAssistant(); await s.openRepositoryAssistant();
    expect(session.active).toBe(true); pending.resolve('{"answer":"Old answer"}'); await send; expect(session.messages).toHaveLength(0); expect(session.working).toBe(false); expect(session.question).toBe("Wait for response");
  });
  it("ignores a late answer after repository reset", async () => {
    const s = store(); await s.openRepositoryAssistant(); const session = s.repositoryAssistant!; session.question = "Wait";
    const pending = defer<string>(); complete.mockReturnValueOnce(pending.promise); const send = s.sendRepositoryQuestion(); await vi.waitFor(() => expect(complete).toHaveBeenCalledTimes(1));
    (s as unknown as { resetState(): void }).resetState(); s.path = "C:/fixture/another"; pending.resolve('{"answer":"Old answer"}'); await send;
    expect(s.repositoryAssistant).toBeNull(); expect(session.messages).toHaveLength(0);
  });
  it("can retry after stopping without closing the conversation", async () => {
    const s = store(); await s.openRepositoryAssistant(); const session = s.repositoryAssistant!; session.question = "Wait";
    const pending = defer<string>(); complete.mockReturnValueOnce(pending.promise);
    const send = s.sendRepositoryQuestion(); await vi.waitFor(() => expect(complete).toHaveBeenCalledTimes(1));
    s.stopRepositoryAssistant(); expect(session.active).toBe(true); expect(session.working).toBe(false);
    pending.resolve('{"answer":"Stopped answer"}'); await send; expect(session.messages).toHaveLength(0);
    await s.sendRepositoryQuestion(); expect(session.messages.at(-1)?.text).toBe("Fixture answer"); expect(session.question).toBe("");
  });
  it("stops before sending if HEAD changed after preview", async () => {
    const s = store(); await s.openRepositoryAssistant(); s.repositoryAssistant!.question = "Current state?";
    call.mockImplementation(async (request) => result(request, "b".repeat(40))); await s.sendRepositoryQuestion(); expect(complete).not.toHaveBeenCalled(); expect(s.repositoryAssistant?.error).toContain("HEAD changed"); expect(s.repositoryAssistant?.question).toBe("Current state?");
  });
  it("stops if a tool observes another HEAD", async () => {
    const s = store(); await s.openRepositoryAssistant(); s.repositoryAssistant!.question = "Read source";
    complete.mockResolvedValueOnce('{"tool":{"name":"read_file","arguments":{"path":"source.ts"}}}'); call.mockImplementation(async (r) => result(r, r.name === "read_file" ? "b".repeat(40) : head));
    await s.sendRepositoryQuestion(); expect(complete).toHaveBeenCalledTimes(1); expect(s.repositoryAssistant?.error).toContain("HEAD changed"); expect(s.repositoryAssistant?.traces[0].error).toContain("HEAD changed");
  });
  it("reports invalid or forbidden tools and keeps the question", async () => {
    const s = store(); await s.openRepositoryAssistant(); s.repositoryAssistant!.question = "Read source";
    complete.mockResolvedValueOnce('{"tool":{"name":"run_shell","arguments":{"command":"anything"}}}'); call.mockImplementation(async (r) => { if (r.name === "run_shell") throw new Error("Unknown read-only tool."); return result(r); });
    await s.sendRepositoryQuestion(); expect(s.repositoryAssistant?.error).toContain("Unknown read-only tool"); expect(s.repositoryAssistant?.question).toBe("Read source"); expect(s.repositoryAssistant?.messages).toHaveLength(0);
  });
  it("ends at the tool budget instead of reading indefinitely", async () => {
    const s = store(); await s.openRepositoryAssistant(); s.repositoryAssistant!.question = "Read repeatedly";
    complete.mockResolvedValue('{"tool":{"name":"read_file","arguments":{"path":"source.ts"}}}'); await s.sendRepositoryQuestion();
    expect(complete).toHaveBeenCalledTimes(7); expect(s.repositoryAssistant?.traces).toHaveLength(6); expect(s.repositoryAssistant?.error).toContain("read limit"); expect(s.repositoryAssistant?.working).toBe(false);
  });
  it("fills a prompt without AI and requires an explicit selection refresh", async () => {
    const s = store(); s.destination = "repository"; s.selection = { kind: "wip" }; await s.openRepositoryAssistant();
    s.useRepositoryPrompt("impact"); expect(complete).not.toHaveBeenCalled(); expect(s.repositoryAssistant?.question).toContain("direct and indirect");
    s.diffSource = { kind: "working", change: { path: "source.ts", oldPath: null, kind: "modified", staged: true } };
    expect(s.repositoryContextStale).toBe(true); await s.sendRepositoryQuestion(); expect(complete).not.toHaveBeenCalled(); expect(s.repositoryAssistant?.error).toContain("selection changed");
    s.refreshRepositorySelection("staged"); expect(s.repositoryContextStale).toBe(false); await s.sendRepositoryQuestion(); expect(complete).toHaveBeenCalledTimes(1); expect(complete.mock.calls[0][1]).toContain('"selectedPaths":["source.ts"]'); expect(complete.mock.calls[0][1]).not.toContain(repository);
  });
  it("discards an answer after selection changes while the request is pending", async () => {
    const s = store(); await s.openRepositoryAssistant(); s.repositoryAssistant!.question = "Wait for current selection";
    const pending = defer<string>(); complete.mockReturnValueOnce(pending.promise); const send = s.sendRepositoryQuestion();
    await vi.waitFor(() => expect(complete).toHaveBeenCalledTimes(1)); s.selection = { kind: "commit", sha: "b".repeat(40) }; pending.resolve('{"answer":"Outdated selection"}'); await send;
    expect(s.repositoryAssistant?.messages).toHaveLength(0); expect(s.repositoryAssistant?.error).toContain("selection changed while AI"); expect(s.repositoryAssistant?.working).toBe(false);
  });
  it("saves edited instructions per repository and resets without freezing selection paths", async () => {
    let overrides: Record<string, Record<string, string>> = {};
    const originalGet = settings.get.bind(settings);
    vi.spyOn(settings, "get").mockImplementation(<T>(key: string, fallback: T): T => key === "workPromptOverrides" ? overrides as T : originalGet(key, fallback));
    vi.spyOn(settings, "set").mockImplementation((key, value) => { if (key === "workPromptOverrides") overrides = value as typeof overrides; });
    const s = store(); await s.openRepositoryAssistant(); s.useRepositoryPrompt("impact");
    s.repositoryAssistant!.question = s.repositoryAssistant!.question.replace("Trace the selected changes", "Custom instruction: trace the selected changes");
    expect(s.saveRepositoryPrompt("impact")).toBe(true);
    s.diffSource = { kind: "working", change: { path: "new.ts", oldPath: null, kind: "modified", staged: false } }; s.useRepositoryPrompt("impact");
    expect(s.repositoryAssistant?.question).toContain("Custom instruction"); expect(s.repositoryAssistant?.question).toContain("new.ts");
    const other = store(); other.path = "C:/fixture/other"; await other.openRepositoryAssistant(); other.useRepositoryPrompt("impact"); expect(other.repositoryAssistant?.question).not.toContain("Custom instruction");
    expect(s.saveRepositoryPrompt("impact", true)).toBe(true); expect(s.repositoryAssistant?.question).not.toContain("Custom instruction"); expect(complete).not.toHaveBeenCalled();
  });
  it("accepts graph actions only against a loaded bounded snapshot", async () => {
    const s = store(); await s.openRepositoryAssistant();
    const graph = { schemaVersion: 1, id: "snapshot-a", nodeIDs: ["source.ts"], edges: [] };
    call.mockImplementation(async (request) => request.name === "graph_context" ? { ...result(request), text: JSON.stringify(graph) } : result(request));
    await s.loadRepositoryGraph(); expect(s.repositoryAssistant?.graphSnapshot).toEqual(graph);
    s.repositoryAssistant!.question = "Explain graph";
    const actions = { schemaVersion: 1, snapshotID: graph.id, actions: [{ kind: "nodes", nodeIDs: ["source.ts"] }] };
    complete.mockResolvedValueOnce(JSON.stringify({ answer: "Known selection", graphActions: actions })); await s.sendRepositoryQuestion();
    expect(s.repositoryAssistant?.messages.at(-1)?.graphActions).toEqual(actions);
    s.repositoryAssistant!.question = "Bad selection";
    complete.mockResolvedValueOnce(JSON.stringify({ answer: "Keep the answer", graphActions: { ...actions, snapshotID: "old" } })); await s.sendRepositoryQuestion();
    expect(s.repositoryAssistant?.messages.at(-1)?.text).toBe("Keep the answer"); expect(s.repositoryAssistant?.messages.at(-1)?.graphActions).toBeUndefined(); expect(s.repositoryAssistant?.error).toContain("invalid or stale graph actions");
  });
});
