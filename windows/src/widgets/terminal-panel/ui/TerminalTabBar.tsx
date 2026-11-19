import { ChevronsRight, Globe } from "lucide-react";
import { ChevronDown, Ellipsis, Plus, X } from "@/shared/icons";
import { agents } from "@/entities/agent";
import type { RepoStore } from "@/entities/repo";
import { activity, type BrowserSession, compactBar, type TabMark, tabActivity, tabMark, TabMarkSlot, tabOverflow, tabStripWidth, type TerminalActivity, type TerminalSession, type TermPane } from "@/entities/terminal";
import { ipc } from "@/shared/api";
import { displayPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { IconButton, type MenuItem, showMenuBelow, tip } from "@/shared/ui";

/** What a tab's status slot and the status line show for a terminal (macOS: TerminalSession.tabStatus) */
export function tabStatus(term: TerminalSession): { mark: TabMark; activity: TerminalActivity; title: string } {
  const { busy, waiting } = tabActivity(agents.statusIn(term), term.busy);
  const exited = !term.running && term.started;
  const mark = tabMark({ exited, busy, unseen: term.unseenOutput, waiting });
  const title = mark === "ring" ? t("Running") : mark === "hollow" ? t("Exited") : mark === "dot" ? (waiting ? t("Waiting for input") : t("New output")) : t("Idle");
  return { mark, activity: activity(exited, busy), title };
}

/**
 * A pane's tab bar: tabs with their status marks, » for the tabs that do not fit, then the pane's buttons.
 * (macOS: TerminalTabBar in TerminalChrome.swift)
 */
export function TerminalTabBar({ pane, shown, corner, width, store }: { pane: TermPane; shown: TerminalSession | BrowserSession | null; corner: boolean; width: number; store: RepoStore }) {
  useObserve(agents);
  const tabs = pane.sessions.map((id) => store.terminals.find((x) => x.id === id) ?? store.browser(id)).filter((x): x is TerminalSession | BrowserSession => !!x);
  const isTerminal = (x: TerminalSession | BrowserSession): x is TerminalSession => "term" in x;
  const select = (x: TerminalSession | BrowserSession) => (isTerminal(x) ? store.selectTerminal(x) : store.selectBrowser(x));
  const compact = compactBar(width);
  const selected = shown ? tabs.indexOf(shown) : -1;
  const { visible, hidden } = tabOverflow(tabs.length, selected >= 0 ? selected : null, tabStripWidth(width, compact ? 1 : corner ? 3 : 2));
  const number = (term: TerminalSession) => (store.terminals.length > 1 ? store.terminals.indexOf(term) + 1 : null);
  const newTerminal = () => {
    if (shown) select(shown);
    store.newTerminal();
  };
  const hide = () => {
    store.showTerminal = false;
    store.changed();
  };
  const overflow = (): MenuItem[] =>
    hidden.map((i) => {
      const tab = tabs[i];
      if (!isTerminal(tab)) return { label: tab.title, shortcut: t("Browser"), onClick: () => select(tab) };
      const n = number(tab);
      return { label: n === null ? tab.title : `${n}  ${tab.title}`, shortcut: tabStatus(tab).title, onClick: () => select(tab) };
    });
  const actions = (): MenuItem[] => [
    ...(compact ? [{ label: t("New terminal"), shortcut: "Ctrl+Shift+`", onClick: newTerminal }] : []),
    { label: t("New browser tab"), tip: t("Opens a web page next to the terminals, such as a dev server."), onClick: () => store.newBrowser() },
    { label: t("Split right"), tip: t("Opens another shell next to this one, in the same folder."), onClick: () => store.splitTerminal(pane.id, "row") },
    { label: t("Split down"), tip: t("Opens another shell below this one, in the same folder."), onClick: () => store.splitTerminal(pane.id, "column") },
    ...(shown && isTerminal(shown)
      ? [{ label: t("Open in external terminal"), tip: t("Opens the current folder ({0}) in a new Windows Terminal window.", displayPath(shown.directory)), onClick: () => void ipc.openTerminal(shown.directory) }]
      : []),
    ...(compact && corner ? ["divider" as const, { label: t("Hide terminal"), shortcut: "Ctrl+`", onClick: hide }] : []),
  ];
  return (
    <div className="term-bar">
      <div className="term-tabs" role="tablist" aria-label={t("Terminals")}>
        {visible.map((i) => {
          const tab = tabs[i];
          return isTerminal(tab) ? <TermTab key={tab.id} term={tab} n={number(tab)} on={tab === shown} store={store} /> : <BrowserTab key={tab.id} page={tab} on={tab === shown} store={store} />;
        })}
      </div>
      {hidden.length > 0 && (
        <button
          type="button"
          className="term-overflow"
          aria-haspopup="menu"
          aria-label={t("{0} more terminals", hidden.length)}
          data-tip={t("{0} more terminals", hidden.length)}
          onClick={(e) => showMenuBelow(e.currentTarget, overflow())}
        >
          <ChevronsRight size={12} />
          {hidden.length}
        </button>
      )}
      {!compact && <IconButton small className="term-new" icon={<Plus size={14} />} aria-label={t("New terminal")} tip={tip(t("New terminal"), t("Opens another shell in the repository folder."), "Ctrl+Shift+`")} onClick={newTerminal} />}
      <span className="spacer" />
      <IconButton small className="term-more" icon={<Ellipsis size={14} />} aria-haspopup="menu" aria-label={t("Terminal actions")} tip={t("Terminal actions")} onClick={(e) => showMenuBelow(e.currentTarget, actions())} />
      {!compact && corner && (
        <IconButton small className="term-hide" icon={<ChevronDown size={15} />} aria-label={t("Hide terminal")} tip={tip(t("Hide terminal"), t("Only the panel is hidden; shells keep running."), "Ctrl+`")} onClick={hide} />
      )}
    </div>
  );
}

function TermTab({ term, n, on, store }: { term: TerminalSession; n: number | null; on: boolean; store: RepoStore }) {
  useObserve(term);
  const status = tabStatus(term);
  return (
    <div className={`term-tab ${on ? "on" : ""}`} data-tip={`${displayPath(term.directory)} · ${status.title}`}>
      <button type="button" className="term-tab-select" role="tab" aria-selected={on} aria-label={`${term.title}, ${status.title}`} onClick={() => store.selectTerminal(term)}>
        <TabMarkSlot mark={status.mark} />
        {n !== null && <span className="term-tab-n">{n}</span>}
        <span className="ellipsis">{term.title}</span>
      </button>
      <IconButton
        small
        className="x"
        icon={<X size={11} />}
        aria-label={t("Close terminal")}
        tip={t("Close terminal")}
        onClick={(e) => {
          e.stopPropagation();
          if (term.running && term.spec.program)
            store.ask({ title: t("Close the terminal?"), message: t("'{0}' is still running. Closing it will stop it.", term.title), actionTitle: t("Close"), action: () => store.closeTerminal(term) });
          else store.closeTerminal(term);
        }}
      />
    </div>
  );
}

function BrowserTab({ page, on, store }: { page: BrowserSession; on: boolean; store: RepoStore }) {
  useObserve(page);
  const state = page.loading ? t("Loading…") : t("Browser");
  return (
    <div className={`term-tab browser ${on ? "on" : ""}`} data-tip={`${page.url ?? page.title} · ${state}`}>
      <button type="button" className="term-tab-select" role="tab" aria-selected={on} aria-label={`${page.title}, ${state}`} onClick={() => store.selectBrowser(page)}>
        <TabMarkSlot mark={page.loading ? "ring" : "none"} />
        <Globe size={11} className="term-tab-globe" aria-hidden />
        <span className="ellipsis">{page.title}</span>
      </button>
      <IconButton
        small
        className="x"
        icon={<X size={11} />}
        aria-label={t("Close tab")}
        tip={t("Close tab")}
        onClick={(e) => {
          e.stopPropagation();
          store.closeBrowser(page);
        }}
      />
    </div>
  );
}
