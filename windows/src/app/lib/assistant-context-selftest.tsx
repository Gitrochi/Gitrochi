import { createRoot } from "react-dom/client";
import { ai } from "@/entities/ai";
import { gitch } from "@/entities/gitch";
import { RepoStore } from "@/entities/repo";
import { RepositoryAssistantSheet } from "@/features/repository-assistant";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { tools } from "@/shared/platform";

const pause = () => new Promise<void>((done) => setTimeout(done, 25));
async function until(check: () => boolean) { for (let attempt = 0; attempt < 150; attempt++) { if (check()) return; await pause(); } throw new Error("Assistant context UI did not settle"); }

/** Drive task selection, context refresh and validated graph selection through the real UI. */
export async function assistantContextSelfTest(): Promise<[boolean, string]> {
  const original = { run: ipc.run, exists: ipc.exists, executable: gitch.executable, bash: gitch.bash, complete: ai.complete, problem: ai.problem, provider: ai.providerFor, node: tools.state.node };
  const host = document.createElement("div"); host.hidden = true; host.dataset.selftest = "assistant-context"; document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const repository = "C:/fixture/context-workspace", head = "a".repeat(40), snapshotID = "b".repeat(64);
  let aiCalls = 0, applied = "";
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent?.trim() === t(label));
  const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
  try {
    store.path = repository; store.headHash = head; store.destination = "repository"; store.selection = { kind: "wip" };
    tools.state.node = { path: "/fixture/node", source: "custom", version: "v22.0.0" };
    ipc.exists = async () => true; gitch.executable = async () => "/fixture/gitch"; gitch.bash = async () => "/fixture/bash";
    ipc.run = async (_program, args) => {
      if (args[0] === "--version") return { status: 0, stdout: "v22.0.0", stderr: "" };
      if (args.includes("--tools")) return { status: 0, stdout: "[]", stderr: "" };
      const at = args.indexOf("--call"); if (at < 0) throw new Error("Unexpected process request");
      const request = JSON.parse(args[at + 1]) as { name: string };
      const text = request.name === "graph_context" ? JSON.stringify({ schemaVersion: 1, id: snapshotID, nodeIDs: ["source.ts"], edges: [], coverage: { truncated: false } }) : "Fixture evidence";
      return { status: 0, stdout: JSON.stringify({ repository, tool: request.name, head, text, truncated: false, readOnly: true }), stderr: "" };
    };
    ai.problem = () => null; ai.providerFor = () => "compatible";
    ai.complete = async () => { aiCalls++; return JSON.stringify({ answer: "SELFTEST_CONTEXT_ANSWER", graphActions: { schemaVersion: 1, snapshotID, actions: [{ kind: "nodes", nodeIDs: ["source.ts"] }] } }); };
    store.openAssistantGraph = async (json) => { applied = json; };
    await store.openRepositoryAssistant(false, false);
    root.render(<RepositoryAssistantSheet store={store} embedded close={() => {}} />); await pause();
    const picker = host.querySelector<HTMLSelectElement>(`select[aria-label="${t("Task prompt")}"]`)!;
    ensure(picker && host.textContent?.includes(t("Screen implementation map")), "Task picker or source mapping missing");
    Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")!.set!.call(picker, "impact"); picker.dispatchEvent(new Event("change", { bubbles: true }));
    await until(() => !!store.repositoryAssistant?.question);
    ensure(aiCalls === 0 && store.repositoryAssistant?.question.includes(t("Scope")), "Choosing a task sent AI or omitted scope");
    store.diffSource = { kind: "working", change: { path: "source.ts", oldPath: null, kind: "modified", staged: true } }; store.changed(); await pause();
    ensure(button("Send question")?.disabled, "Changed selection did not disable Send");
    button("Refresh selection context")?.click(); await pause(); ensure(!store.repositoryContextStale, "Selection refresh did not capture the current diff");
    button("Load graph context")?.click(); await until(() => !!store.repositoryAssistant?.graphSnapshot);
    ensure(aiCalls === 0 && host.textContent?.includes(t("Graph coverage and snapshot")), "Graph context loading called AI or hid coverage");
    button("Send question")?.click(); await until(() => host.textContent?.includes("SELFTEST_CONTEXT_ANSWER") === true);
    ensure(aiCalls === 1, "Explicit Send did not issue exactly one AI call");
    button("Apply graph selection")?.click(); await until(() => !!applied);
    ensure(JSON.parse(applied).snapshotID === snapshotID, "Validated graph envelope did not reach the graph command");
    return [true, "Task picker without AI, selection refresh, bounded graph context, typed answer actions and graph command passed"];
  } finally {
    root.unmount(); host.remove(); store.cancelRepositoryAssistant();
    ipc.run = original.run; ipc.exists = original.exists; gitch.executable = original.executable; gitch.bash = original.bash;
    ai.complete = original.complete; ai.problem = original.problem; ai.providerFor = original.provider; tools.state.node = original.node;
  }
}
