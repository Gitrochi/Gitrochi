import { useEffect, useRef, useState } from "react";
import { graphWorkspaceLink, structureGraphDocument } from "@/entities/gitch";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { describe } from "@/shared/platform";
import { Button, Modal, Spinner } from "@/shared/ui";
import "./structure-graph.css";

/** Reuses the offline graph renderer inside a restricted document sandbox. */
export function StructureGraphSheet({ store, file, liveUrl, repository, head, actionsJSON, generation, close }: {
  store: RepoStore; file: string; liveUrl?: string; repository: string; head: string | null; actionsJSON?: string; generation?: number; close: () => void;
}) {
  useObserve(store);
  const frame = useRef<HTMLIFrameElement>(null);
  const [html, setHTML] = useState<string | null>(null);
  const [error, setError] = useState("");
  const stale = store.path !== repository || store.headHash !== head;
  useEffect(() => {
    let active = true;
    setHTML(null); setError("");
    void ipc.readText(file).then(value => {
      if (!active) return;
      if (value === null) throw new Error(t("The graph document could not be read."));
      setHTML(structureGraphDocument(value, actionsJSON));
    }).catch((reason: unknown) => { if (active) setError(describe(reason)); });
    return () => { active = false; };
  }, [file, actionsJSON, generation]);
  useEffect(() => {
    const receive = (event: MessageEvent<unknown>) => {
      if (event.source !== frame.current?.contentWindow || store.path !== repository || stale) return;
      if (!event.data || typeof event.data !== "object" || !("type" in event.data) || event.data.type !== "gitrochi-graph-open" || !("url" in event.data)) return;
      const url = graphWorkspaceLink(event.data.url, repository);
      if (url) void ipc.openUrl(url).catch((reason: unknown) => setError(describe(reason)));
    };
    window.addEventListener("message", receive);
    return () => window.removeEventListener("message", receive);
  }, [repository, stale, store]);
  return <Modal title={t("Structure graph workspace")} width={1200} onClose={close} footer={<>
    <Button disabled={store.path !== repository || !!store.graphJob} onClick={() => void store.openStructureGraph("files")}>{t("Refresh graph")}</Button>
    <Button onClick={() => void (liveUrl ? ipc.openUrl(liveUrl) : ipc.openHtml(file)).catch((reason: unknown) => setError(describe(reason)))}>{t("Open in browser")}</Button>
    <span className="spacer" /><Button onClick={close}>{t("Close")}</Button>
  </>}>
    <span className="hint">{t("This workspace shows an offline analysis snapshot. Refresh after editing files.")}</span>
    {stale && <span role="status" className="hint">{t("The repository or HEAD changed. Refresh the analysis before using this snapshot.")}</span>}
    {error && <span role="alert">{error}</span>}
    {!html && !error && <span className="row"><Spinner />{t("Loading graph workspace…")}</span>}
    {html && <iframe ref={frame} className="structure-graph-frame" title={t("Structure graph")} sandbox="allow-scripts allow-downloads" srcDoc={html} />}
  </Modal>;
}
