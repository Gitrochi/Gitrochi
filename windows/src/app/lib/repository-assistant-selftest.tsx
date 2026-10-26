import type { ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { ai } from "@/entities/ai";
import { gitch } from "@/entities/gitch";
import { RepoStore } from "@/entities/repo";
import { workspace } from "@/entities/workspace";
import { RepositoryAssistantSheet, MCPConnectionSheet } from "@/features/repository-assistant";
import { WorkspaceOverviewSheet } from "@/features/workspace-overview";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { tools } from "@/shared/platform";

const pause = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
async function until(check: () => boolean) { for (let i = 0; i < 150; i++) { if (check()) return true; await pause(20); } return false; }

/** 실제 UI를 조작하되 AI·프로세스·계정 호출은 모두 가짜로 대체한다. */
export async function repositoryAssistantSelfTest(): Promise<[boolean, string]> {
  const original = { run: ipc.run, exists: ipc.exists, executable: gitch.executable, bash: gitch.bash, complete: ai.complete, problem: ai.problem, provider: ai.providerFor, node: tools.state.node, tabs: workspace.tabs, activeId: workspace.activeId };
  const host = document.createElement("div"); host.hidden = true; host.dataset.selftest = "repository-assistant"; document.body.append(host);
  let root = createRoot(host);
  const mount = async (view: ReactNode) => { root.render(view); await pause(25); };
  const reset = () => { root.unmount(); host.replaceChildren(); root = createRoot(host); };
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find((el) => el.textContent?.trim() === t(label));
  const ensure = (value: boolean, message: string) => { if (!value) throw new Error(message); };
  const sha = "a".repeat(40), repository = "C:/gitrochi-assistant-fixture";
  const calls: string[] = []; let aiCalls = 0;
  let holdCatalog = true, catalogBlocked = false, releaseCatalog = () => {};
  const store = new RepoStore(); store.path = repository; store.headHash = sha;
  try {
    tools.state.node = { path: "/fixture/node", source: "custom", version: "v22.0.0" };
    ipc.exists = async () => true;
    gitch.executable = async () => "/fixture/gitch"; gitch.bash = async () => "/fixture/bash";
    ipc.run = async (_program, args) => {
      if (args[0] === "--version") return { status: 0, stdout: "v22.0.0", stderr: "" };
      if (args.includes("--tools")) {
        const catalog = { status: 0, stdout: JSON.stringify([{ name: "read_file", inputSchema: { type: "object", properties: { path: { type: "string" } } } }]), stderr: "" };
        if (holdCatalog) { holdCatalog = false; catalogBlocked = true; return new Promise((resolve) => { releaseCatalog = () => resolve(catalog); }); }
        return catalog;
      }
      const index = args.indexOf("--call");
      if (index < 0) throw new Error("Unexpected process request");
      const request = JSON.parse(args[index + 1]) as { name: string };
      calls.push(request.name);
      return { status: 0, stdout: JSON.stringify({ repository, tool: request.name, text: request.name === "read_file" ? "source.txt:1: const example = true;" : "fixture context", head: sha, truncated: false, readOnly: true }), stderr: "" };
    };
    ai.problem = () => null; ai.providerFor = () => "compatible";
    ai.complete = async () => { aiCalls++; return aiCalls === 1 ? JSON.stringify({ tool: { name: "read_file", arguments: { path: "source.txt" } } }) : JSON.stringify({ answer: "SELFTEST_REPOSITORY_ANSWER: source.txt:1 contains the example." }); };
    const interruptedPreparation = store.openRepositoryAssistant(false, false);
    ensure(await until(() => catalogBlocked), "Assistant preparation did not reach its fixture gate");
    await mount(<RepositoryAssistantSheet store={store} embedded close={() => {}} />);
    ensure(store.repositoryAssistant?.loading === true, "Preparation indicator missing");
    reset();
    await store.openRepositoryAssistant(false, false);
    const prepared = store.repositoryAssistant;
    releaseCatalog(); await interruptedPreparation;
    ensure(store.repositoryAssistant === prepared && prepared?.loading === false && !!prepared.runtime, "Returning after interrupted preparation left the assistant stuck loading");
    await store.openRepositoryAssistant();
    await mount(<RepositoryAssistantSheet store={store} close={() => { store.sheet = null; }} />);
    ensure(aiCalls === 0 && !!host.querySelector("details pre"), "Opening the assistant called AI or omitted the context preview");
    const input = host.querySelector<HTMLTextAreaElement>(`textarea[aria-label="${t("Question about this repository")}"]`)!;
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(input, "Where is the example defined?");
    input.dispatchEvent(new Event("input", { bubbles: true }));
    ensure(await until(() => button("Send question")?.disabled === false), "Question input did not enable Send");
    button("Send question")!.click();
    ensure(await until(() => host.textContent?.includes("SELFTEST_REPOSITORY_ANSWER") === true), "Repository answer did not render");
    ensure(aiCalls === 2 && calls.filter((name) => name === "read_file").length === 1 && !!host.textContent?.includes(t("Read activity")), "Read tool loop or activity transcript did not match the request");
    reset();
    await mount(<MCPConnectionSheet store={store} close={() => {}} />);
    ensure(await until(() => host.textContent?.includes("mcpServers") === true), "MCP configuration was not rendered");
    button("Test connection")!.click();
    ensure(await until(() => host.textContent?.includes(t("Read-only connection works.")) === true), "MCP test did not execute the fake status reader");
    reset();
    let refreshes = 0;
    store.ci.load = async () => { refreshes++; };
    store.loadInbox = async () => { refreshes++; store.inboxKind = "review"; };
    store.target = { provider: "github", host: "github.example.invalid", path: "fixture/repository", remote: "origin" };
    workspace.tabs = [store]; workspace.activeId = store.id;
    await mount(<WorkspaceOverviewSheet store={store} close={() => {}} />);
    ensure(!!host.textContent?.includes(repository) && !!button("Open repository"), "Workspace overview omitted the open repository");
    button("Refresh hosting summaries")!.click();
    ensure(await until(() => refreshes === 2), "Workspace refresh did not use the selected repository services");
    return [true, "Repository AI: preview without AI, question input, bounded read tool and answer/activity; MCP config/test; workspace selected repository summary refresh"];
  } finally {
    root.unmount(); host.remove(); store.cancelRepositoryAssistant();
    ipc.run = original.run; ipc.exists = original.exists; gitch.executable = original.executable; gitch.bash = original.bash;
    ai.complete = original.complete; ai.problem = original.problem; ai.providerFor = original.provider; tools.state.node = original.node;
    workspace.tabs = original.tabs; workspace.activeId = original.activeId;
  }
}
