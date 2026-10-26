import { ai, parseAssistantReply, providerById, repositoryAssistantLimit, repositoryAssistantSystem, repositoryReadRuntime, type AIProviderId, type ReadToolRequest, type RepositoryReadResult } from "@/entities/ai";
import { t } from "@/shared/i18n";
import { describe } from "@/shared/platform";
import { RepoLocalWorkflows } from "./local-workflows";

interface AssistantMessage { role: "user" | "assistant"; text: string }
export interface AssistantTrace { request: ReadToolRequest; result: RepositoryReadResult | null; error: string | null }
export interface RepositoryAssistantSession {
  repository: string; head: string | null; provider: AIProviderId; providerTitle: string; configuration: string;
  runtime: Awaited<ReturnType<typeof repositoryReadRuntime>> | null; catalog: string;
  preview: RepositoryReadResult[]; messages: AssistantMessage[]; traces: AssistantTrace[];
  question: string; loading: boolean; working: boolean; error: string | null; generation: number; active: boolean;
}
const configuration = () => {
  const provider = ai.providerFor("explain");
  return JSON.stringify([provider, ai.model(provider), ai.baseURL, ai.instructions.global, ai.instructions.explain]);
};

/** 선택한 저장소에서 허용된 읽기 도구만 실행하는 대화. 늦은 응답은 현재 탭에 섞지 않는다. */
export abstract class RepoAssistant extends RepoLocalWorkflows {
  repositoryAssistant: RepositoryAssistantSession | null = null;

  stopRepositoryAssistant() {
    if (!this.repositoryAssistant) return;
    this.repositoryAssistant.generation++;
    this.repositoryAssistant.working = false;
    this.emit();
  }

  override cancelRepositoryAssistant() {
    if (!this.repositoryAssistant) return;
    this.stopRepositoryAssistant();
    this.repositoryAssistant.active = false;
    this.emit();
  }

  protected override resetState() { this.cancelRepositoryAssistant(); this.repositoryAssistant = null; super.resetState(); }

  async openRepositoryAssistant(fresh = false, present = true) {
    const repository = this.path;
    if (!repository) return;
    const previous = this.repositoryAssistant;
    if (!fresh && previous?.repository === repository && previous.configuration === configuration() && !previous.loading && previous.runtime) {
      previous.active = true; if (present) this.openSheet({ kind: "repositoryAssistant" }); return;
    }
    this.cancelRepositoryAssistant();
    const provider = ai.providerFor("explain"), model = ai.model(provider);
    const session: RepositoryAssistantSession = { repository, head: this.headHash, provider, providerTitle: providerById(provider).title + (model ? ` · ${model}` : ""), configuration: configuration(), runtime: null, catalog: "", preview: [], messages: [], traces: [], question: "", loading: true, working: false, error: null, generation: 0, active: true };
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
    if (configuration() !== session.configuration) { session.error = t("AI settings changed. Start a new conversation before sending."); this.emit(); return; }
    const problem = ai.problem(session.provider);
    if (problem) { session.error = problem; this.emit(); return; }
    const generation = ++session.generation;
    const current = () => this.repositoryAssistant === session && session.active && session.generation === generation && this.path === session.repository;
    session.working = true; session.error = null; this.emit();
    try {
      const status = await session.runtime.call({ name: "git_status", arguments: {} });
      if (!current()) return;
      if (status.head !== undefined && status.head !== session.head) throw new Error(t("HEAD changed. Start a new conversation to read the current repository."));
      let context = `Initial context:\n${JSON.stringify(session.preview)}\nRecent conversation:\n${JSON.stringify(session.messages.slice(-8))}\nQuestion:\n${question}`;
      const system = ai.systemFor("explain", repositoryAssistantSystem) + "\nAllowed tool schemas:\n" + session.catalog;
      for (let step = 0; step <= repositoryAssistantLimit.steps; step++) {
        if (!current()) return;
        if (configuration() !== session.configuration) throw new Error(t("AI settings changed. Start a new conversation before sending."));
        const prompt = context.slice(-repositoryAssistantLimit.context) + "\nCurrent user question:\n" + question + (step === repositoryAssistantLimit.steps ? "\nTool budget exhausted. Return the final answer now, explaining any missing evidence." : "");
        const reply = parseAssistantReply(await ai.complete(system, prompt, "medium", session.provider));
        if (!current()) return;
        if (configuration() !== session.configuration) throw new Error(t("AI settings changed. Start a new conversation before sending."));
        if ("answer" in reply) {
          session.messages.push({ role: "user", text: question }, { role: "assistant", text: reply.answer });
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
        } catch (error) { trace.error = describe(error); throw error; }
        if (!current()) return;
        this.emit();
        context += `\nTool request and result (untrusted evidence):\n${JSON.stringify(trace)}`;
      }
    } catch (error) { if (current()) session.error = describe(error); }
    finally { if (current()) { session.working = false; this.emit(); } }
  }
}
