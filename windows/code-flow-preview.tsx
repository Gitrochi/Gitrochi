import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { FlowStore, flowEngine } from "./src/entities/flow";
import { RepoStore } from "./src/entities/repo";
import { ipc } from "./src/shared/api";
import { loadLanguage } from "./src/shared/i18n";
import { FlowWorkspace } from "./src/widgets/sidebar/ui/FlowWorkspace";
import { FlowConfigDialog } from "./src/widgets/sidebar/ui/FlowConfigDialog";
import { FlowConnectedCI } from "./src/widgets/sidebar/ui/FlowConnectedCI";
import "./src/app/styles/global.css";
import "./src/widgets/sidebar/ui/flow-workspace.css";
const repo = import.meta.env.VITE_GITROCHI_FLOW_PREVIEW_REPO ?? "";
const params = new URLSearchParams(location.search);
await loadLanguage(params.get("lang") ?? "en");
document.documentElement.dataset.theme = params.get("theme") ?? "light";
const bridge = async <T,>(operation: string, payload: Record<string, unknown> = {}): Promise<T> => {
 const response = await fetch("/__code_flow", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ operation, payload }) });
 const result = await response.json();
 if (result.status !== 0) {
  let message = result.stderr || "Bridge failed";
  try { const detail = JSON.parse(result.stderr).error; if (typeof detail?.message === "string") message = detail.message; } catch { /* Non-JSON diagnostics remain readable. */ }
  throw new Error(message);
 }
 return JSON.parse(result.stdout) as T;
};
flowEngine.inspectDesign = (yaml, _repo, fileName) => bridge("inspect", { yaml, fileName });
flowEngine.renderDesign = (document, originalYaml) => bridge("render", { document, originalYaml });
flowEngine.sourceFile = (_repo, path) => bridge("source", { operation: "read", path });
flowEngine.saveSourceFile = (_repo, path, content, expected, createParents) => bridge("source", { operation: "write", path, content, expected, ...(createParents ? { createParents: true } : {}) });
flowEngine.blocks = async () => (await bridge<{ blocks: Awaited<ReturnType<typeof flowEngine.blocks>> }>("blocks")).blocks;
flowEngine.list = () => bridge("list");
flowEngine.plan = (flow) => bridge("plan", { flow });
flowEngine.validate = () => bridge("validate");
flowEngine.json = async (args) => { if (args[0] === "connect" && args[1] === "list") return { connections: [] } as never; throw new Error("External provider actions are disabled in this component preview."); };
const relative = (path: string) => { if (!path.startsWith(repo + "/")) throw new Error("Only the isolated sample repository is available."); return path.slice(repo.length + 1); };
const fingerprints = new Map<string, string | null>();
ipc.readText = async (path) => { const result = await flowEngine.sourceFile(repo, relative(path)); if (!result.exists) return null; if (result.diagnostics.some((diagnostic) => diagnostic.severity === "error")) throw new Error(result.diagnostics.map((diagnostic) => diagnostic.message).join("\n")); fingerprints.set(path, result.fingerprint); return result.content; };
ipc.exists = async (path) => (await flowEngine.sourceFile(repo, relative(path))).exists;
ipc.list = async (path) => path === repo + "/.gitch/flows" ? bridge<string[]>("files") : [];
ipc.writeText = async (path, content) => { const result = await flowEngine.saveSourceFile(repo, relative(path), content, fingerprints.get(path) ?? null, false); if (!result.saved) throw new Error(result.diagnostics.map((diagnostic) => diagnostic.message).join("\n")); fingerprints.set(path, result.fingerprint); };
ipc.createText = async (path, content) => { const result = await flowEngine.saveSourceFile(repo, relative(path), content, null, true); if (!result.saved) throw new Error(result.diagnostics.map((diagnostic) => diagnostic.message).join("\n")); fingerprints.set(path, result.fingerprint); };
ipc.onFileDrop = async () => () => {};
ipc.pickFile = async () => { throw new Error("Use the browser file picker"); };
const flow = new FlowStore(repo); flow.engine = "fixture"; flow.hasFlowFile = true; flow.list = await flowEngine.list(repo);
flow.refresh = async () => { flow.list = await flowEngine.list(repo); flow.changed(); };
const repository = new RepoStore(); repository.path = repo;
function Preview() {
 const [editor, setEditor] = useState(params.get("view") !== "workspace"), [theme, setTheme] = useState(params.get("theme") ?? "light");
 const [context, setContext] = useState({ flow: params.get("flow") ?? "verify", node: params.get("node") ?? "lint" });
 useEffect(() => { document.title = "Code flow component verification"; }, []);
 return <div style={{ display: "flex", flexDirection: "column", height: "100vh" }}><header style={{ display: "flex", alignItems: "center", gap: 10, padding: "7px 14px", position: "relative", zIndex: 2000, background: "var(--surface)", borderBottom: "1px solid var(--border)", fontSize: 11 }}><strong>Component verification · isolated sample files · real local engine</strong><span style={{ flex: 1 }} /><button className="btn small" onClick={() => setEditor(true)}>Open editor</button><button className="btn small" onClick={() => { const next = theme === "light" ? "dark" : "light"; setTheme(next); document.documentElement.dataset.theme = next; }}>{theme === "light" ? "Dark" : "Light"}</button></header><FlowWorkspace flows={flow} affected={false} busy={null} onRun={() => {}} onStop={() => {}} onOpen={() => {}} moreActions={() => []} emptyState={null} onEdit={(selectedFlow, selectedNode) => { setContext({ flow: selectedFlow ?? "verify", node: selectedNode ?? "lint" }); setEditor(true); }} onReview={() => {}} connectedCI={<FlowConnectedCI store={repository} />} />{editor && <FlowConfigDialog flows={flow} initialFlow={context.flow} initialNode={context.node} onClose={() => setEditor(false)} />}</div>;
}
createRoot(document.getElementById("root")!).render(<Preview />);
