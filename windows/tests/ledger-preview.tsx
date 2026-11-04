import { createRoot } from "react-dom/client";
import { ledgerSelfTest } from "../src/app/lib/ledger-selftest";
import { ledgerBrowserSelfTest } from "../src/app/lib/ledger-browser-selftest";
import { ledgerConnectionsSelfTest } from "../src/app/lib/ledger-connections-selftest";
import { ledgerChatGPTDraftSelfTest } from "../src/app/lib/ledger-chatgpt-draft-selftest";
import { ledgerParitySelfTest } from "../src/app/lib/ledger-parity-selftest";
import { ledgerRequestSelfTest } from "../src/app/lib/ledger-request-selftest";
import { ledgerFlowSelfTest } from "../src/app/lib/ledger-flow-selftest";
import { ledgerHubSelfTest } from "../src/app/lib/ledger-hub-selftest";
import { handleShortcut } from "../src/app/lib/shortcuts";
import { DemoLedgerBackend, LedgerStore, type LedgerView, type LedgerVerdict } from "../src/entities/ledger";
import { RepoStore } from "../src/entities/repo";
import { workspace } from "../src/entities/workspace";
import { RepoPage } from "../src/pages/repo";
import { ipc } from "../src/shared/api";
import { env, initEnv, settings } from "../src/shared/config";
import { loadLanguage } from "../src/shared/i18n";
import { MenuHost, TooltipHost } from "../src/shared/ui";
import { LedgerWorkspace } from "../src/widgets/ledger-workspace";
import { SettingsDialog } from "../src/widgets/settings";
import "../src/app/styles/global.css";

// The Ledger page on the demo backend: ?theme=dark&view=board&select=needs_human&activity=1&mode=empty|large|app|settings|selftest
const params = new URLSearchParams(location.search);
await initEnv({ ...env, os: "windows", resourceDir: "C:\\Program Files\\Gitrochi" });
await loadLanguage(params.get("lang") ?? "en");
document.documentElement.dataset.theme = params.get("theme") ?? "light";
const root = document.getElementById("root")!;
const mode = params.get("mode");
if (mode === "selftest") {
  // As in the app, its own shortcuts listen on window from start-up, before the Ledger adds its keys; a Ctrl+Z
  // that reaches the repository's undo opens its confirmation
  const confirmation = Object.assign(document.createElement("div"), { className: "modal-backdrop" });
  Object.defineProperty(workspace, "active", { get: () => workspace.tabs.find((tab) => tab.id === workspace.activeId) ?? workspace.tabs[0] ?? ({ path: "C:/fixture/app", confirmUndo: () => document.body.append(confirmation) }) });
  window.addEventListener("keydown", (e) => handleShortcut(e, () => {}));
  createRoot(root).render(<MenuHost />);
  const checks = [await ledgerSelfTest(), await ledgerChatGPTDraftSelfTest(), await ledgerBrowserSelfTest(), await ledgerConnectionsSelfTest(), await ledgerParitySelfTest(), await ledgerRequestSelfTest(), await ledgerFlowSelfTest(), await ledgerHubSelfTest()];
  const passed = checks.every(([ok]) => ok);
  const detail = checks.map(([, message]) => message).join("\n");
  const result = document.createElement("pre");
  result.id = "ledger-selftest-result";
  result.dataset.passed = String(passed);
  result.textContent = `${passed ? "PASSED" : "FAILED"}: ${detail}`;
  document.body.append(result);
} else if (mode === "app") {
  // the real window shell: the page list with the Ledger under Tools, the page title and the Ledger on the app's demo store
  env.ledgerDemo = "1";
  ipc.openUrl = async () => {};
  const app = new RepoStore();
  app.loadGlobalIdentity = async () => {};
  app.navigate("ledger");
  root.style.height = "100vh";
  createRoot(root).render(<><RepoPage store={app} openSettings={() => {}} /><MenuHost /><TooltipHost /></>);
} else if (mode === "settings") {
  // Settings › Ledger on the app's demo store
  env.ledgerDemo = "1";
  ipc.ledgerPickDatabase = async () => "C:/Tools/claude-ledger/data/ledger.db";
  createRoot(root).render(<><SettingsDialog onClose={() => {}} initialTab="ledger" /><MenuHost /><TooltipHost /></>);
  // ?scroll=<selector> brings a settings section into view for a screenshot
  const section = params.get("scroll");
  if (section) setTimeout(() => document.querySelector(section)?.scrollIntoView({ block: "start" }), 800);
} else {
  ipc.openUrl = async () => {};
  const repoPath = "C:/Projects/atlas";
  const backend = new DemoLedgerBackend({ repoPath, lively: mode !== "questions" && mode !== "reported", large: mode === "large", empty: mode === "empty" });
  const demoOwner = backend.world.sessions.find((session) => session.project === "atlas" && session.status === "active" && !session.stream);
  if (demoOwner && (mode === "questions" || mode === "reported")) {
    backend.world.prompts = [];
    backend.world.questions = [];
    if (mode === "questions") backend.world.prompts.push({ id: backend.world.nextPrompt++, sessionId: demoOwner.id, kind: "ask_user_question", state: "waiting", createdAt: Date.now(), deadline: Date.now() + 15 * 60_000, payload: { autoAnswer: false, questions: [
      { header: "Report format", question: "How should the results be presented?", options: [{ label: "Brief summary", description: "Focus on outcomes and next steps", recommended: true }, { label: "Detailed report", description: "Include the evidence and tradeoffs" }] },
      { header: "Validation", question: "Which checks should be included?", multiSelect: true, options: [{ label: "Unit tests", description: "Check the core behavior", recommended: true }, { label: "Browser checks", description: "Exercise the complete workflow" }] },
      { header: "Follow-up", question: "Anything else to include?", suggestedAnswer: "Include remaining risks and the next action.", options: [] },
    ] } });
    else backend.world.questions.push({ id: backend.world.nextQuestion++, sessionId: demoOwner.id, text: "How should the review results be shared?", options: [{ label: "Brief summary", description: "Focus on outcomes and next steps", recommended: true }, { label: "Detailed report", description: "Include the evidence and tradeoffs" }], suggestedAnswer: "Use a brief summary with links to the evidence.", state: params.has("answered") ? "answered" : "open", ...(params.has("answered") ? { answer: "Use a brief summary with links to the evidence.", answeredBy: "human" as const, answeredAt: Date.now() } : {}), createdAt: Date.now() });
    if (mode === "reported" && params.has("browser")) {
      const question = backend.world.questions[0];
      question.browserSourceUrl = "https://chatgpt.com/uc/00000000-0000-4000-8000-000000000042";
      question.browserDraft = "Use a brief summary after the checks pass.";
    }
    backend.world.rev++;
  }
  const store = new LedgerStore(backend);
  if (params.has("learn")) {
    const step = Math.max(0, Math.min(4, Number(params.get("step")) || 0));
    settings.set("ledgerLearning", { version: 1, step, completed: false, answerSent: step > 2, deliveryState: step > 3 ? "archived" : "saved" });
  }
  store.setView((params.get("view") as LedgerView | null) ?? "inbox");
  store.setProjectChoice(params.get("project") ?? "repository");
  await store.refresh(true);
  const select = params.get("select") as LedgerVerdict | null;
  if (params.has("activity")) {
    const session = backend.world.sessions.find((s) => s.id === store.state?.sessions.find((item) => item.verdict === select)?.id);
    if (session) {
      const now = Date.now();
      for (let i = 0; i < 36; i++) backend.world.events.push({ id: backend.world.nextEvent++, sessionId: session.id, actor: "hook", type: "hook", ts: now - i * 1000, summary: "Observed tool activity" });
      session.lastAt = now;
      backend.world.rev++;
      await store.refresh(true);
    }
  }
  if (select) store.select(store.state?.sessions.find((s) => s.verdict === select)?.id ?? null);
  else if (mode === "reported" && params.has("answered") && demoOwner) store.select(demoOwner.id);
  root.style.height = "100vh";
  if (params.get("width")) root.style.width = `${params.get("width")}px`;
  createRoot(root).render(<><LedgerWorkspace repoPath={repoPath} ledger={store} /><MenuHost /><TooltipHost /></>);
  if (params.has("learn")) {
    await new Promise((resolve) => setTimeout(resolve, 300));
    document.querySelector<HTMLElement>("[data-learn-ledger]")?.click();
    if (params.get("learn") === "guide") {
      await new Promise((resolve) => setTimeout(resolve, 100));
      document.querySelector<HTMLElement>(".ledger-learning-tabs button[id$='-guide']")?.click();
    }
  }
  // ?click=<selector>;<selector> opens a sheet or menu for a screenshot
  for (const selector of (params.get("click") ?? "").split(";").filter(Boolean)) {
    await new Promise((resolve) => setTimeout(resolve, 300));
    document.querySelector<HTMLElement>(selector)?.click();
  }
  // ?hover=<selector> shows a toolbar button's tooltip for a screenshot
  const hover = params.get("hover");
  if (hover) {
    await new Promise((resolve) => setTimeout(resolve, 300));
    document.querySelector(hover)?.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
  }
}
