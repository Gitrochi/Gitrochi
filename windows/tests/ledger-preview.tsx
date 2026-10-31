import { createRoot } from "react-dom/client";
import { ledgerSelfTest } from "../src/app/lib/ledger-selftest";
import { DemoLedgerBackend, LedgerStore, type LedgerView, type LedgerVerdict } from "../src/entities/ledger";
import { RepoStore } from "../src/entities/repo";
import { RepoPage } from "../src/pages/repo";
import { ipc } from "../src/shared/api";
import { env, initEnv } from "../src/shared/config";
import { loadLanguage } from "../src/shared/i18n";
import { MenuHost, TooltipHost } from "../src/shared/ui";
import { LedgerWorkspace } from "../src/widgets/ledger-workspace";
import "../src/app/styles/global.css";

// The Ledger page on the demo backend in a browser: ?theme=dark&lang=ko&view=board&select=needs_human&width=900&click=<selector>&mode=empty|large|app|selftest
const params = new URLSearchParams(location.search);
await initEnv({ ...env, os: "windows", resourceDir: "C:\\Program Files\\Gitrochi" });
await loadLanguage(params.get("lang") ?? "en");
document.documentElement.dataset.theme = params.get("theme") ?? "light";
const root = document.getElementById("root")!;
const mode = params.get("mode");
if (mode === "selftest") {
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
  ipc.openUrl = async () => {};
  const app = new RepoStore();
  app.loadGlobalIdentity = async () => {};
  app.navigate("ledger");
  root.style.height = "100vh";
  createRoot(root).render(<><RepoPage store={app} openSettings={() => {}} /><MenuHost /><TooltipHost /></>);
} else {
  ipc.openUrl = async () => {};
  const repoPath = "C:/Projects/atlas";
  const store = new LedgerStore(new DemoLedgerBackend({ repoPath, lively: true, large: mode === "large", empty: mode === "empty" }));
  store.setView((params.get("view") as LedgerView | null) ?? "inbox");
  store.setProjectChoice(params.get("project") ?? "repository");
  await store.refresh(true);
  const select = params.get("select") as LedgerVerdict | null;
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
