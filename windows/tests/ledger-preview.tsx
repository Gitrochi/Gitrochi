import { createRoot } from "react-dom/client";
import { ledgerSelfTest } from "../src/app/lib/ledger-selftest";
import { handleShortcut } from "../src/app/lib/shortcuts";
import { DemoLedgerBackend, LedgerStore, type LedgerView, type LedgerVerdict } from "../src/entities/ledger";
import { RepoStore } from "../src/entities/repo";
import { workspace } from "../src/entities/workspace";
import { RepoPage } from "../src/pages/repo";
import { ipc } from "../src/shared/api";
import { env, initEnv } from "../src/shared/config";
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
  const [passed, detail] = await ledgerSelfTest();
  const result = document.createElement("pre");
  result.id = "ledger-selftest-result";
  result.dataset.passed = String(passed);
  result.textContent = `${passed ? "PASSED" : "FAILED"}: ${detail}`;
  document.body.append(result);
} else if (mode === "app") {
  // the real window shell: the page list with the Ledger under Tools, the page title and the Ledger on the app's demo store
  env.ledgerPreview = "1";
  env.ledgerDemo = "1";
  ipc.openUrl = async () => {};
  const app = new RepoStore();
  app.loadGlobalIdentity = async () => {};
  app.navigate("ledger");
  root.style.height = "100vh";
  createRoot(root).render(<><RepoPage store={app} openSettings={() => {}} /><MenuHost /><TooltipHost /></>);
} else if (mode === "settings") {
  // Settings › Ledger on the app's demo store
  env.ledgerPreview = "1";
  env.ledgerDemo = "1";
  ipc.ledgerPickDatabase = async () => "C:/Tools/claude-ledger/data/ledger.db";
  createRoot(root).render(<><SettingsDialog onClose={() => {}} initialTab="ledger" /><MenuHost /><TooltipHost /></>);
} else {
  ipc.openUrl = async () => {};
  const repoPath = "C:/Projects/atlas";
  const backend = new DemoLedgerBackend({ repoPath, lively: true, large: mode === "large", empty: mode === "empty" });
  const store = new LedgerStore(backend);
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
  root.style.height = "100vh";
  if (params.get("width")) root.style.width = `${params.get("width")}px`;
  createRoot(root).render(<><LedgerWorkspace repoPath={repoPath} ledger={store} /><MenuHost /><TooltipHost /></>);
  // ?click=<selector>;<selector> opens a sheet or menu for a screenshot
  for (const selector of (params.get("click") ?? "").split(";").filter(Boolean)) {
    await new Promise((resolve) => setTimeout(resolve, 300));
    document.querySelector<HTMLElement>(selector)?.click();
  }
}
