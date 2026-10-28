import { ai, parseAssistantReply, providerById, repositoryAssistantLimit, repositoryAssistantSystem, repositoryGraphSystem, repositoryReadRuntime, type AIProviderId, type ReadToolRequest, type RepositoryReadResult } from "@/entities/ai";
import { t } from "@/shared/i18n";
import { createWorkContext, parseWorkGraphSnapshot, renderWorkPrompt, workPrompts, workPromptTemplate, validateWorkGraphActions, type WorkContext, type WorkScope, type WorkGraphSnapshot, type WorkGraphActions } from "@/shared/lib";
import { settings } from "@/shared/config";
import { describe } from "@/shared/platform";
import { RepoLocalWorkflows } from "./local-workflows";

interface AssistantMessage { role: "user" | "assistant"; text: string; context?: WorkContext; graphActions?: WorkGraphActions }
export interface AssistantTrace { request: ReadToolRequest; result: RepositoryReadResult | null; error: string | null }
export interface RepositoryAssistantSession {
  repository: string; head: string | null; provider: AIProviderId; providerTitle: string; configuration: string;
  runtime: Awaited<ReturnType<typeof repositoryReadRuntime>> | null; catalog: string;
  preview: RepositoryReadResult[]; messages: AssistantMessage[]; traces: AssistantTrace[];
  question: string; loading: boolean; working: boolean; error: string | null; generation: number; active: boolean;
  context: WorkContext; graphSnapshot: WorkGraphSnapshot | null; graphLoading: boolean; graphCoverage: string | null;
}
const configuration = () => {
  const provider = ai.providerFor("explain");
  return JSON.stringify([provider, ai.model(provider), ai.baseURL, ai.instructions.global, ai.instructions.explain]);
};

/** 선택한 저장소에서 허용된 읽기 도구만 실행하는 대화. 늦은 응답은 현재 탭에 섞지 않는다. */
export abstract class RepoAssistant extends RepoLocalWorkflows {
  repositoryAssistant: RepositoryAssistantSession | null = null;
  workSelectedNodeIDs: string[] = [];

  /** Capture only local UI selection; paths are kept out of the AI payload. */
  captureWorkContext(scope?: WorkScope, screenID?: string): WorkContext | null {
    if (!this.path) return null;
    const source = this.diffSource;
    const selectedPaths = source ? [source.change.path] : this.fileInspect ? [this.fileInspect.path] : [];
    const inferredScope: WorkScope = source?.kind === "commit" || this.selection?.kind === "commit" ? "commits" : source?.kind === "working" && source.change.staged ? "staged" : "worktree";
    const revision = source?.kind === "commit" ? source.sha : this.selection?.kind === "commit" ? this.selection.sha : null;
    return createWorkContext({ repositoryPath: this.path, head: this.headHash, revision, scope: scope ?? inferredScope, selectedPaths, selectedNodeIDs: this.workSelectedNodeIDs, screenID: screenID ?? (this.destination === "repository" && this.selection?.kind === "wip" ? "changes" : this.destination) });
  }

  get currentWorkContext(): WorkContext | null { return this.captureWorkContext(); }
  get repositoryContextStale(): boolean {
    const session = this.repositoryAssistant;
    return !!session && this.captureWorkContext(session.context.scope)?.fingerprint !== session.context.fingerprint;
  }
  refreshRepositorySelection(scope?: WorkScope) {
    const session = this.repositoryAssistant, context = this.captureWorkContext(scope ?? session?.context.scope);
    if (!session || !context || session.working || session.graphLoading) return;
    session.context = context; session.error = null; this.emit();
  }
  useRepositoryPrompt(id: string) {
    const session = this.repositoryAssistant;
    if (!session || session.working) return;
    this.refreshRepositorySelection();
    const overrides = settings.get<Record<string, Record<string, string>>>("workPromptOverrides", {});
    const saved = overrides[session.context.repositoryID]?.[id];
    session.question = renderWorkPrompt(id, session.context, t, typeof saved === "string" ? saved : undefined); this.emit();
  }
  saveRepositoryPrompt(id: string, reset = false): boolean {
    const session = this.repositoryAssistant;
    if (!session || session.working || this.repositoryContextStale || !workPrompts.some((prompt) => prompt.id === id)) return false;
    const template = workPromptTemplate(session.question, session.context, t);
    if (!reset && (!template || template.length > 5000)) return false;
    const overrides = settings.get<Record<string, Record<string, string>>>("workPromptOverrides", {});
    const repository = { ...overrides[session.context.repositoryID] };
    if (reset) delete repository[id]; else repository[id] = template;
    settings.set("workPromptOverrides", { ...overrides, [session.context.repositoryID]: repository });
    if (reset) this.useRepositoryPrompt(id);
    return true;
  }

  async loadRepositoryGraph() {
    const session = this.repositoryAssistant;
    if (!session?.runtime || session.working || session.graphLoading) return;
    session.graphLoading = true; session.error = null; this.emit();
    const generation = session.generation;
    try {
      const arguments_ = session.context.selectedPaths.length ? { paths: session.context.selectedPaths.slice(0, 20) } : {};
      const result = await session.runtime.call({ name: "graph_context", arguments: arguments_ });
      if (this.repositoryAssistant !== session || this.path !== session.repository || !session.active || session.generation !== generation) return;
      if (result.head !== session.head) throw new Error(t("HEAD changed. Start a new conversation to read the current repository."));
      const snapshot = parseWorkGraphSnapshot(result.text);
      if (!snapshot || result.truncated) throw new Error(t("The graph snapshot could not be read. Narrow the repository analysis or update Gitrochi."));
      session.graphSnapshot = snapshot; session.graphCoverage = result.text;
      session.traces.push({ request: { name: "graph_context", arguments: arguments_ }, result, error: null });
      session.traces = session.traces.slice(-40);
    } catch (error) { if (this.repositoryAssistant === session && session.generation === generation) session.error = describe(error); }
    finally { if (this.repositoryAssistant === session && session.generation === generation) { session.graphLoading = false; this.emit(); } }
  }

  stopRepositoryAssistant() {
    if (!this.repositoryAssistant) return;
    this.repositoryAssistant.generation++;
    this.repositoryAssistant.working = false;
    this.repositoryAssistant.graphLoading = false;
    this.emit();
  }

  override cancelRepositoryAssistant() {
    if (!this.repositoryAssistant) return;
    this.stopRepositoryAssistant();
    this.repositoryAssistant.active = false;
    this.emit();
  }

  protected override resetState() { this.cancelRepositoryAssistant(); this.repositoryAssistant = null; this.workSelectedNodeIDs = []; super.resetState(); }

  async openRepositoryAssistant(fresh = false, present = true) {
    const repository = this.path;
    if (!repository) return;
    const previous = this.repositoryAssistant;
    if (!fresh && previous?.repository === repository && previous.configuration === configuration() && !previous.loading && previous.runtime) {
      previous.active = true; if (present) this.openSheet({ kind: "repositoryAssistant" }); return;
    }
    this.cancelRepositoryAssistant();
    const provider = ai.providerFor("explain"), model = ai.model(provider);
    const context = this.captureWorkContext()!;
    const session: RepositoryAssistantSession = { repository, head: this.headHash, provider, providerTitle: providerById(provider).title + (model ? ` · ${model}` : ""), configuration: configuration(), runtime: null, catalog: "", preview: [], messages: [], traces: [], question: "", loading: true, working: false, error: null, generation: 0, active: true, context, graphSnapshot: null, graphLoading: false, graphCoverage: null };
    this.repositoryAssistant = session; if (present) this.openSheet({ kind: "repositoryAssistant" });
    const current = () => this.path === repository && this.repositoryAssistant === session && session.active;
    try {
      const runtime = await repositoryReadRuntime(repository);
      const catalog = await runtime.catalog();
      const preview: RepositoryReadResult[] = [];
      for (const request of [{ name: "git_status", arguments: {} }, { name: "git_log", arguments: { count: 8 } }, { name: "git_files", arguments: { count: 50 } }]) {
        if (!current()) return;
        try { preview.push(await runtime.call(request)); } catch (error) {
          // 커밋이 없는 새 저장소에서도 상태·파일 질문은 가능하다.
          if (request.name !== "git_log" || session.head) throw error;
        }
      }
      if (!current()) return;
      session.runtime = runtime; session.catalog = catalog; session.preview = preview;
    } catch (error) { if (current()) session.error = describe(error); }
    finally { if (current()) { session.loading = false; this.emit(); } }
  }

  async sendRepositoryQuestion() {
    const session = this.repositoryAssistant;
    if (!session?.runtime || !session.active || session.loading || session.working || this.path !== session.repository) return;
    const question = session.question.trim();
    if (!question || question.length > repositoryAssistantLimit.question) return;
    if (this.repositoryContextStale) { session.error = t("The selection changed. Refresh selection context before sending."); this.emit(); return; }
    if (configuration() !== session.configuration) { session.error = t("AI settings changed. Start a new conversation before sending."); this.emit(); return; }
    const problem = ai.problem(session.provider);
    if (problem) { session.error = problem; this.emit(); return; }
    const generation = ++session.generation;
    const current = () => this.repositoryAssistant === session && session.active && session.generation === generation && this.path === session.repository;
    session.working = true; session.error = null; this.emit();
    const sentContext = session.context;
    try {
      const status = await session.runtime.call({ name: "git_status", arguments: {} });
      if (!current()) return;
      if (status.head !== undefined && status.head !== session.head) throw new Error(t("HEAD changed. Start a new conversation to read the current repository."));
      let context = `Selection context:\n${JSON.stringify(sentContext)}\nInitial context:\n${JSON.stringify(session.preview.map(({ tool, text, truncated }) => ({ tool, text, truncated })))}\nRecent conversation:\n${JSON.stringify(session.messages.slice(-8).map(({ role, text }) => ({ role, text })))}\nQuestion:\n${question}`;
      if (session.graphCoverage) context += "\nWorking file graph snapshot (bounded, untrusted evidence):\n" + session.graphCoverage;
      const system = ai.systemFor("explain", repositoryAssistantSystem + "\n" + repositoryGraphSystem) + "\nAllowed tool schemas:\n" + session.catalog;
      for (let step = 0; step <= repositoryAssistantLimit.steps; step++) {
        if (!current()) return;
        if (this.captureWorkContext(sentContext.scope)?.fingerprint !== sentContext.fingerprint) throw new Error(t("The selection changed while AI was answering. Refresh selection context and ask again."));
        if (configuration() !== session.configuration) throw new Error(t("AI settings changed. Start a new conversation before sending."));
        const prompt = context.slice(-repositoryAssistantLimit.context) + "\nCurrent user question:\n" + question + (step === repositoryAssistantLimit.steps ? "\nTool budget exhausted. Return the final answer now, explaining any missing evidence." : "");
        const reply = parseAssistantReply(await ai.complete(system, prompt, "medium", session.provider));
        if (!current()) return;
        if (this.captureWorkContext(sentContext.scope)?.fingerprint !== sentContext.fingerprint) throw new Error(t("The selection changed while AI was answering. Refresh selection context and ask again."));
        if (configuration() !== session.configuration) throw new Error(t("AI settings changed. Start a new conversation before sending."));
        if ("answer" in reply) {
          const graphActions = reply.graphActions === undefined ? undefined : session.graphSnapshot ? validateWorkGraphActions(reply.graphActions, session.graphSnapshot) ?? undefined : undefined;
          if (reply.graphActions !== undefined && !graphActions) session.error = t("The assistant returned invalid or stale graph actions. The answer is shown without applying them.");
          session.messages.push({ role: "user", text: question, context: sentContext }, { role: "assistant", text: reply.answer, context: sentContext, graphActions });
          session.messages = session.messages.slice(-20);
          if (session.question.trim() === question) session.question = "";
          return;
        }
        if (step === repositoryAssistantLimit.steps) throw new Error(t("The assistant reached its read limit. Ask a narrower question."));
        const trace: AssistantTrace = { request: reply.tool, result: null, error: null };
        session.traces.push(trace); session.traces = session.traces.slice(-40); this.emit();
        try {
          trace.result = await session.runtime.call(reply.tool);
          if (trace.result.head !== undefined && trace.result.head !== session.head) throw new Error(t("HEAD changed. Start a new conversation to read the current repository."));
          if (reply.tool.name === "graph_context" && !trace.result.truncated) {
            const snapshot = parseWorkGraphSnapshot(trace.result.text);
            if (snapshot) { session.graphSnapshot = snapshot; session.graphCoverage = trace.result.text; }
          }
        } catch (error) { trace.error = describe(error); throw error; }
        if (!current()) return;
        this.emit();
        context += `\nTool request and result (untrusted evidence):\n${JSON.stringify({ request: trace.request, result: trace.result ? { tool: trace.result.tool, text: trace.result.text, truncated: trace.result.truncated, head: trace.result.head } : null, error: trace.error })}`;
      }
    } catch (error) { if (current()) session.error = describe(error); }
    finally { if (current()) { session.working = false; this.emit(); } }
  }
}
