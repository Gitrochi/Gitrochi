import { createRoot } from "react-dom/client";
import { RepoStore } from "@/entities/repo";
import { StructureGraphSheet } from "@/features/structure-graph";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";

/** Exercises the real sandbox shell while isolating file and navigation calls. */
export async function structureGraphSelfTest(): Promise<[boolean, string]> {
  const original = { readText: ipc.readText, openUrl: ipc.openUrl, openHtml: ipc.openHtml };
  const host = document.createElement("div"); host.hidden = true; document.body.append(host);
  const root = createRoot(host), store = new RepoStore();
  const repository = "C:/graph-fixture", head = "a".repeat(40), opened: string[] = [];
  store.path = repository; store.headHash = head;
  const pause = () => new Promise<void>(resolve => setTimeout(resolve, 25));
  const ensure = (value: boolean, message: string) => { if (!value) throw new Error(message); };
  try {
    ipc.readText = async () => '<!doctype html><html><head></head><body><script id="graph-data" type="application/json">{}</script></body></html>';
    ipc.openUrl = async url => { opened.push(url); };
    ipc.openHtml = async path => { opened.push(path); };
    root.render(<StructureGraphSheet store={store} file="C:/fixture/graph.html" repository={repository} head={head} close={() => {}} />);
    for (let i = 0; i < 100 && !host.querySelector("iframe"); i++) await pause();
    const frame = host.querySelector("iframe");
    ensure(!!frame && frame.sandbox.value === "allow-scripts allow-downloads", "Graph workspace sandbox is missing");
    ensure(frame!.srcdoc.includes("connect-src 'none'"), "Graph workspace permits network resources");
    const link = "gitrochi://open?repo=C%3A%2Fgraph-fixture&view=graph&file=src%2Fmain.ts&line=2";
    window.dispatchEvent(new MessageEvent("message", { source: window, data: { type: "gitrochi-graph-open", url: link } }));
    ensure(opened.length === 0, "Graph accepted navigation from another window");
    window.dispatchEvent(new MessageEvent("message", { source: frame!.contentWindow, data: { type: "gitrochi-graph-open", url: link } }));
    await pause();
    ensure(opened.length === 1, "Graph source navigation did not reach the app");
    store.headHash = "b".repeat(40); store.changed(); await pause();
    ensure(host.textContent?.includes(t("The repository or HEAD changed. Refresh the analysis before using this snapshot.")) === true, "Graph freshness notice is missing");
    window.dispatchEvent(new MessageEvent("message", { source: frame!.contentWindow, data: { type: "gitrochi-graph-open", url: link } }));
    ensure(opened.length === 1, "Stale graph navigated using the wrong revision");
    return [true, "Embedded graph sandbox, source navigation and revision freshness passed."];
  } catch (error) { return [false, String(error)]; }
  finally { root.unmount(); host.remove(); Object.assign(ipc, original); }
}
