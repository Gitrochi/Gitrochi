import { ClipboardPaste, DatabaseBackup, Inbox, PlugZap, Search, SquareKanban, Timer, Waves, Waypoints } from "lucide-react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { agents } from "@/entities/agent";
import { inboxCount, inboxGroups, type LedgerPendingPrompt, type LedgerSearchHit, type LedgerStore, ledgerLayout, ledgerStore, type LedgerView } from "@/entities/ledger";
import { LedgerConnectSheet } from "@/features/connect-ledger-mcp";
import { LedgerImportSheet, LedgerLegacyImportSheet } from "@/features/import-ledger-reports";
import { isMac, keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, IconButton, Modal, Spinner } from "@/shared/ui";
import { LedgerBoard } from "./LedgerBoard";
import { LedgerFilters, LedgerTopBar } from "./LedgerFilters";
import { LedgerGraph } from "./LedgerGraph";
import { LedgerInbox } from "./LedgerInbox";
import { LedgerInspector } from "./LedgerInspector";
import { visiblePrompts } from "./LedgerPromptStrip";
import { LedgerSearch } from "./LedgerSearch";
import { LedgerStreams } from "./LedgerStreams";
import { onScreen, typing } from "./parts";
import "./ledger-workspace.css";

type Sheet = "import" | "legacy" | "connect" | "search" | null;

const views: { id: LedgerView; label: string; icon: typeof Inbox }[] = [
  { id: "inbox", label: "Inbox", icon: Inbox },
  { id: "board", label: "Board", icon: SquareKanban },
  { id: "graph", label: "Graph", icon: Waypoints },
  { id: "streams", label: "Streams", icon: Waves },
];

/**
 * The Ledger page: what each agent session was for, which baseline it started from and where it stands. Filters |
 * view | inspector; below 1,080 px the inspector opens as a sheet and below 640 px the filters stack above the view.
 * Opens without a repository and filters to the open one's project. (macOS: Views/Ledger/LedgerWorkspaceView.swift)
 */
export function LedgerWorkspace({ repoPath, ledger }: { repoPath: string | null; ledger?: LedgerStore }) {
  const store = useObserve(ledger ?? ledgerStore(repoPath));
  useEffect(() => store.start(), [store]);
  const root = useRef<HTMLDivElement>(null);
  const repo = useRef(repoPath);
  repo.current = repoPath;
  useEffect(() => {
    store.setRepository(repoPath);
  }, [store, repoPath]);
  const [width, setWidth] = useState(1200);
  const [sheet, setSheet] = useState<Sheet>(null);
  const [inspectorOpen, setInspectorOpen] = useState(false);
  // A hidden tab keeps its page mounted; the one that comes back on screen makes its repository the current one again
  useLayoutEffect(() => {
    const el = root.current;
    if (!el) return;
    const measure = () => {
      setWidth(el.clientWidth);
      if (el.clientWidth > 0) store.setRepository(repo.current);
    };
    const ro = new ResizeObserver(measure);
    measure();
    ro.observe(el);
    return () => ro.disconnect();
  }, [store, !!store.state]);
  const layout = ledgerLayout(width);
  const open = (sessionId: string, eventId: number | null = null) => {
    store.select(sessionId, eventId);
    if (layout !== "wide") setInspectorOpen(true);
  };

  // Ctrl+K searches the Ledger; Ctrl+Z takes back the operation the toast shows (instead of the repository's undo).
  // The terminal panel keeps both: they mean something to the shell.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = isMac() ? e.metaKey : e.ctrlKey;
      if (!mod || e.shiftKey || e.altKey || e.defaultPrevented || !onScreen(root.current) || (e.target as HTMLElement | null)?.closest?.(".xterm")) return;
      const key = e.key.toLowerCase();
      if (key === "k" && !document.querySelector(".modal-backdrop")) {
        e.preventDefault();
        e.stopPropagation();
        setSheet("search");
      } else if (key === "z" && store.toast?.undo && !typing(e)) {
        e.preventDefault();
        e.stopPropagation();
        void store.undo();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [store]);

  const openTerminal = (prompt: LedgerPendingPrompt) => {
    const agentId = prompt.agentId ?? store.session(prompt.sessionId)?.links.agentId;
    const agent = agentId ? agents.sessions.find((a) => a.id === agentId) : undefined;
    if (agent && agents.canFocus(agent)) agents.focus(agent);
    else store.showToast(t("The agent's terminal is not open in Gitrochi. Answer it where the agent runs."), null);
  };
  const pick = (hit: LedgerSearchHit) => {
    if (hit.sessionId) open(hit.sessionId, hit.kind === "event" ? Number(hit.id) : null);
    else if (hit.kind === "baseline") store.setView("graph");
  };

  if (!store.state) {
    return (
      <div className="ledger-page" ref={root}>
        {store.error ? <div className="col grow" style={{ alignItems: "center", justifyContent: "center", gap: 10 }}><Empty title={t("The Ledger could not be read")} detail={store.error} /><Button onClick={() => void store.refresh(true)}>{t("Try again")}</Button></div> : <div className="ledger-onboarding"><Spinner size={18} /></div>}
      </div>
    );
  }

  const empty = !store.state.sessions.length && !store.state.pendingPrompts.length && !store.state.hiddenBefore;
  const groups = inboxGroups(store.state, store.project);
  const counts: Partial<Record<LedgerView, number>> = { inbox: inboxCount(groups), streams: store.state.sessions.filter((s) => s.stream && (!store.project || s.project === store.project)).length };
  const waiting = visiblePrompts(store).length;
  const selected = !!store.selectedId;
  const inspector = <LedgerInspector key={store.selectedId ?? ""} store={store} onClose={layout === "wide" ? undefined : () => setInspectorOpen(false)} />;
  return (
    <div className={`ledger-page ${layout}`} ref={root} data-layout={layout}>
      {layout !== "narrow" && !empty && <LedgerFilters store={store} repoPath={repoPath} />}
      <div className="ledger-main">
        {layout === "narrow" && !empty && <LedgerTopBar store={store} repoPath={repoPath} />}
        <div className="ledger-toolbar" role="toolbar" aria-label={t("Ledger")}>
          {!empty && (
            <div className="ledger-tabs" role="tablist" aria-label={t("Views")}>
              {views.map((v) => (
                <button key={v.id} type="button" role="tab" aria-selected={store.view === v.id} className={store.view === v.id ? "on" : ""} onClick={() => store.setView(v.id)} data-view={v.id}>
                  <v.icon size={14} />
                  {t(v.label)}
                  {!!counts[v.id] && <span className="counter">{counts[v.id]}</span>}
                </button>
              ))}
            </div>
          )}
          {waiting > 0 && store.view !== "inbox" && (
            <button type="button" className="ledger-waiting-pill" onClick={() => store.setView("inbox")} data-tip={t("Agents waiting for an answer")}>
              <Timer size={12} />
              {t("{0} waiting", waiting)}
            </button>
          )}
          <span className="spacer" />
          {store.backend.kind === "demo" && <span className="ledger-demo-pill" data-tip={`${t("Demo data")}|${t("GITROCHI_LEDGER_DEMO is set, so the Ledger shows example sessions instead of the ledger database.")}`}>{t("Demo data")}</span>}
          <IconButton icon={<Search size={16} />} tip={`${t("Search the Ledger")}||${keyLabel("Ctrl+K")}`} aria-label={t("Search the Ledger")} onClick={() => setSheet("search")} />
          <IconButton icon={<ClipboardPaste size={16} />} tip={`${t("Paste reports")}|${t("Import report blocks from a conversation.")}`} aria-label={t("Paste reports")} onClick={() => setSheet("import")} />
          <IconButton icon={<PlugZap size={16} />} tip={`${t("Connect Claude Code")}|${t("Let agents report to the Ledger.")}`} aria-label={t("Connect Claude Code")} onClick={() => setSheet("connect")} />
        </div>
        {store.error && <div className="ledger-banner" role="alert">{store.error}<span className="spacer" /><Button size="small" onClick={() => void store.refresh(true)}>{t("Try again")}</Button></div>}
        {empty ? (
          <Onboarding onConnect={() => setSheet("connect")} onImport={() => setSheet("import")} onImportLegacy={() => setSheet("legacy")} />
        ) : store.repositoryWithoutSessions && store.view !== "graph" ? (
          <div className="ledger-view"><Empty title={t("No sessions for this repository")} detail={t("Agents working here have not reported to the Ledger yet.")} /><div className="row" style={{ justifyContent: "center" }}><Button onClick={() => store.setProjectChoice("all")}>{t("Show all projects")}</Button></div></div>
        ) : (
          <div className={`ledger-view${store.view === "board" || store.view === "graph" ? " fixed" : ""}`} data-view={store.view}>
            {store.view === "inbox" && <LedgerInbox store={store} onOpen={open} onOpenTerminal={openTerminal} />}
            {store.view === "board" && <LedgerBoard store={store} onOpen={open} />}
            {store.view === "graph" && <LedgerGraph store={store} onOpen={open} />}
            {store.view === "streams" && <LedgerStreams store={store} onOpen={open} />}
          </div>
        )}
      </div>
      {layout === "wide" && !empty && (
        <aside className="ledger-inspector-column" aria-label={t("Inspector")}>
          {selected ? inspector : <div className="ledger-placeholder"><Empty title={t("Select a session")} detail={t("Its questions, timeline and links show here.")} /></div>}
        </aside>
      )}
      {layout !== "wide" && inspectorOpen && selected && (
        <Modal width={Math.min(620, width - 24)} onClose={() => setInspectorOpen(false)}>
          <div className="ledger-inspector-sheet">{inspector}</div>
        </Modal>
      )}
      {sheet === "import" && <LedgerImportSheet store={store} onClose={() => setSheet(null)} onOpenSession={(id) => { setSheet(null); open(id); }} onImportLegacy={() => setSheet("legacy")} />}
      {sheet === "legacy" && <LedgerLegacyImportSheet store={store} onClose={() => setSheet(null)} />}
      {sheet === "connect" && <LedgerConnectSheet store={store} onClose={() => setSheet(null)} />}
      {sheet === "search" && <LedgerSearch store={store} onClose={() => setSheet(null)} onPick={pick} />}
      <LedgerToast store={store} />
    </div>
  );
}

function Onboarding({ onConnect, onImport, onImportLegacy }: { onConnect: () => void; onImport: () => void; onImportLegacy: () => void }) {
  return (
    <div className="ledger-onboarding">
      <Empty icon={<Waypoints size={34} strokeWidth={1.4} />} title={t("No agent sessions yet")} detail={t("The Ledger keeps track of what each agent session was for, which baseline it started from and whether its result was merged. You answer, confirm and clean up.")} />
      <div className="ledger-onboarding-steps">
        <div className="card">
          <strong>{t("Connect Claude Code")}</strong>
          <span className="hint">{t("Agents report their sessions through the Ledger's MCP server.")}</span>
          <Button kind="primary" onClick={onConnect}><PlugZap size={14} />{t("Connect Claude Code")}</Button>
        </div>
        <div className="card">
          <strong>{t("Paste reports")}</strong>
          <span className="hint">{t("For agents that cannot reach this computer: paste the report blocks they wrote.")}</span>
          <Button onClick={onImport}><ClipboardPaste size={14} />{t("Paste reports")}</Button>
        </div>
        <div className="card">
          <strong>{t("Import from claude-ledger")}</strong>
          <span className="hint">{t("Moving from claude-ledger? Bring its sessions, questions and baselines along.")}</span>
          <Button onClick={onImportLegacy}><DatabaseBackup size={14} />{t("Import…")}</Button>
        </div>
      </div>
    </div>
  );
}

function LedgerToast({ store }: { store: LedgerStore }) {
  useObserve(store);
  const toast = store.toast;
  if (!toast) return null;
  return (
    <div className={`ledger-toast${toast.error ? " error" : ""}`} role={toast.error ? "alert" : "status"} key={toast.id}>
      <span>{toast.message}</span>
      {toast.undo && <button type="button" onClick={() => void store.undo()} data-tip={keyLabel("Ctrl+Z")}>{t("Undo")}</button>}
    </div>
  );
}
