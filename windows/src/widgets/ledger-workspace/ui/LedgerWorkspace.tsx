import { BookOpen, ClipboardPaste, DatabaseBackup, Globe, Inbox, MessageSquare, PlugZap, Search, SquareKanban, SquareTerminal, Timer, Waves, Waypoints } from "lucide-react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { agents } from "@/entities/agent";
import { filterSessions, inboxCount, inboxGroups, type LedgerPendingPrompt, type LedgerSearchHit, type LedgerStore, ledgerLayout, ledgerStore, ledgerTracking, type LedgerView } from "@/entities/ledger";
import { LedgerConnectSheet } from "@/features/connect-ledger-mcp";
import { LedgerImportSheet, LedgerLegacyImportSheet } from "@/features/import-ledger-reports";
import { LedgerBrowserSheet } from "@/features/connect-chatgpt-browser";
import { LedgerChatGPTDraftSheet } from "@/features/transfer-chatgpt-draft";
import { isMac, keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, IconButton, Modal, showMenuBelow, Spinner } from "@/shared/ui";
import { type LedgerLauncher, quickLaunchItems } from "../lib/quick-launch";
import { LedgerBoard } from "./LedgerBoard";
import { LedgerTopBar } from "./LedgerFilters";
import { LedgerGraph } from "./LedgerGraph";
import { LedgerInbox } from "./LedgerInbox";
import { LedgerInspector } from "./LedgerInspector";
import { LedgerLearning } from "./LedgerLearning";
import { visiblePrompts } from "./LedgerPromptStrip";
import { LedgerSearch } from "./LedgerSearch";
import { LedgerStreams } from "./LedgerStreams";
import { onScreen, typing } from "./parts";
import "./ledger-workspace.css";

type Sheet = "import" | "legacy" | "connect" | "search" | "learning" | "chatgpt" | "browser" | null;

const views: { id: LedgerView; label: string; icon: typeof Inbox }[] = [
  { id: "inbox", label: "Inbox", icon: Inbox },
  { id: "board", label: "Board", icon: SquareKanban },
  { id: "graph", label: "Graph", icon: Waypoints },
  { id: "streams", label: "Streams", icon: Waves },
];

/**
 * The Ledger page: what each agent session was for, which baseline it started from and where it stands. Tabs and
 * compact filters sit above the view; below 1,080 px the inspector opens as a sheet and below 640 px controls wrap.
 * Opens without a repository and filters to the open one's project. `launcher` is the repository's tab, for the quick
 * launches. (macOS: Views/Ledger/LedgerWorkspaceView.swift)
 */
export function LedgerWorkspace({ repoPath, ledger, launcher }: { repoPath: string | null; ledger?: LedgerStore; launcher?: LedgerLauncher }) {
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
  // the overview's CLI is looked up when the menu opens; the tab may have been opened before the app found it
  const quickLaunch = async (anchor: HTMLElement) => {
    if (!repoPath || !launcher) return;
    const demo = store.backend.kind === "demo";
    const cli = demo ? null : await ledgerTracking.cli();
    showMenuBelow(anchor, quickLaunchItems({ launcher, repoPath, project: store.project, cli, demo }));
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
  const counts: Partial<Record<LedgerView, number>> = {
    inbox: inboxCount(groups),
    board: filterSessions(store.state.sessions, { project: store.project, verdicts: store.verdicts, text: store.filterText, showArchived: store.showArchived, unreportedOnly: store.unreportedOnly }).length,
    streams: store.state.sessions.filter((s) => s.stream && (!store.project || s.project === store.project)).length,
  };
  const waiting = visiblePrompts(store).length;
  const selected = !!store.selectedId;
  const inspector = <LedgerInspector key={store.selectedId ?? ""} store={store} onClose={layout === "wide" ? undefined : () => setInspectorOpen(false)} />;
  return (
    <div className={`ledger-page ${layout}`} ref={root} data-layout={layout}>
      <div className="ledger-main">
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
          <div className="ledger-toolbar-actions">
            {store.backend.kind === "demo" && <span className="ledger-demo-pill" data-tip={`${t("Demo data")}|${t("GITROCHI_LEDGER_DEMO is set, so the Ledger shows example sessions instead of the ledger database.")}`}>{t("Demo data")}</span>}
            <Button size="small" data-learn-ledger onClick={() => setSheet("learning")}><BookOpen size={14} />{t("Learn Ledger")}</Button>
            <IconButton icon={<Globe size={16} />} tip={t("ChatGPT browser extension")} aria-label={t("ChatGPT browser extension")} data-chatgpt-browser onClick={() => setSheet("browser")} />
            <IconButton icon={<MessageSquare size={16} />} tip={t("Bring a ChatGPT draft…")} aria-label={t("Bring a ChatGPT draft…")} onClick={() => setSheet("chatgpt")} />
            <IconButton icon={<Search size={16} />} tip={`${t("Search the Ledger")}||${keyLabel("Ctrl+K")}`} aria-label={t("Search the Ledger")} onClick={() => setSheet("search")} />
            <IconButton icon={<ClipboardPaste size={16} />} tip={`${t("Paste reports")}|${t("Import report blocks from a conversation.")}`} aria-label={t("Paste reports")} onClick={() => setSheet("import")} />
            <IconButton icon={<PlugZap size={16} />} tip={`${t("Connect agents")}|${t("Let agents report to the Ledger.")}`} aria-label={t("Connect agents")} onClick={() => setSheet("connect")} />
            <div className="ledger-quick-launch">
              <IconButton icon={<SquareTerminal size={16} />} disabled={!repoPath || !launcher} tip={`${t("Open in the terminal below")}|${t("Ledger overview")} · Claude Code`} aria-label={t("Open in the terminal below")} data-quick-launch onClick={(e) => void quickLaunch(e.currentTarget)} />
              {(!repoPath || !launcher) && <span className="hint">{t("Open a repository to use its terminal")}</span>}
            </div>
          </div>
        </div>
        {!empty && <LedgerTopBar store={store} repoPath={repoPath} />}
        {store.error && <div className="ledger-banner" role="alert">{store.error}<span className="spacer" /><Button size="small" onClick={() => void store.refresh(true)}>{t("Try again")}</Button></div>}
        {empty ? (
          <Onboarding onConnect={() => setSheet("connect")} onImport={() => setSheet("import")} onImportLegacy={() => setSheet("legacy")} onLearn={() => setSheet("learning")} onBrowser={() => setSheet("browser")} />
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
      {sheet === "learning" && <LedgerLearning onClose={() => setSheet(null)} onConnect={() => setSheet("connect")} onImport={() => setSheet("import")} onBringChatGPT={() => setSheet("chatgpt")} onBrowser={() => setSheet("browser")} />}
      {sheet === "browser" && <LedgerBrowserSheet store={store} onClose={() => setSheet(null)} />}
      {sheet === "chatgpt" && <LedgerChatGPTDraftSheet store={store} onClose={() => setSheet(null)} onOpenQuestion={(sessionId) => { store.setView("inbox"); open(sessionId); }} />}
      <LedgerToast store={store} />
    </div>
  );
}

function Onboarding({ onConnect, onImport, onImportLegacy, onLearn, onBrowser }: { onConnect: () => void; onImport: () => void; onImportLegacy: () => void; onLearn: () => void; onBrowser: () => void }) {
  return (
    <div className="ledger-onboarding">
      <Empty icon={<Waypoints size={34} strokeWidth={1.4} />} title={t("No reports yet")} detail={t("No reports have arrived yet. Register the tools, then ask your agent to send a start report.")} />
      <div className="row"><Button data-learn-ledger onClick={onLearn}><BookOpen size={14} />{t("Learn Ledger")}</Button><Button onClick={onBrowser}><Globe size={14} />{t("ChatGPT browser extension")}</Button></div>
      <span className="hint">{t("To track new Claude Code agents launched from Gitrochi automatically, turn on Settings > Ledger > Track agents I start. It is off by default.")}</span>
      <div className="ledger-onboarding-steps">
        <div className="card">
          <strong>{t("Connect agents")}</strong>
          <span className="hint">{t("The Ledger shows reports agents send about their work. Connecting tools alone does not import conversations.")}</span>
          <Button kind="primary" onClick={onConnect}><PlugZap size={14} />{t("Connect agents")}</Button>
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
