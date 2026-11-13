import { ChevronsRight } from "lucide-react";
import { ChevronDown, Ellipsis, Plus, X } from "@/shared/icons";
import { agents } from "@/entities/agent";
import type { RepoStore } from "@/entities/repo";
import { activity, compactBar, type TabMark, tabActivity, tabMark, tabOverflow, tabStripWidth, type TerminalActivity, type TerminalSession, type TermPane } from "@/entities/terminal";
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

/** The 12px slot every tab reserves, so titles never shift when a mark appears */
export function TabMarkSlot({ mark }: { mark: TabMark }) {
  return (
    <span className="term-mark-slot" aria-hidden="true">
      <span className={`term-mark ${mark}`} data-mark={mark} />
    </span>
  );
}

/**
 * A pane's tab bar: tabs with their status marks, » for the tabs that do not fit, then the pane's buttons.
 * (macOS: TerminalTabBar in TerminalChrome.swift)
 */
export function TerminalTabBar({ pane, shown, corner, width, store }: { pane: TermPane; shown: TerminalSession | null; corner: boolean; width: number; store: RepoStore }) {
  useObserve(agents);
  const tabs = pane.sessions.map((id) => store.terminals.find((x) => x.id === id)).filter((x): x is TerminalSession => !!x);
  const compact = compactBar(width);
  const selected = shown ? tabs.indexOf(shown) : -1;
  const { visible, hidden } = tabOverflow(tabs.length, selected >= 0 ? selected : null, tabStripWidth(width, compact ? 1 : corner ? 3 : 2));
  const number = (term: TerminalSession) => (store.terminals.length > 1 ? store.terminals.indexOf(term) + 1 : null);
  const newTerminal = () => {
    if (shown) store.selectTerminal(shown);
    store.newTerminal();
  };
  const hide = () => {
    store.showTerminal = false;
    store.changed();
  };
  const overflow = (): MenuItem[] =>
    hidden.map((i) => {
      const term = tabs[i];
      const n = number(term);
      return { label: n === null ? term.title : `${n}  ${term.title}`, shortcut: tabStatus(term).title, onClick: () => store.selectTerminal(term) };
    });
  const actions = (): MenuItem[] => [
    ...(compact ? [{ label: t("New terminal"), shortcut: "Ctrl+Shift+`", onClick: newTerminal }] : []),
    { label: t("Split right"), tip: t("Opens another shell next to this one, in the same folder."), onClick: () => store.splitTerminal(pane.id, "row") },
    { label: t("Split down"), tip: t("Opens another shell below this one, in the same folder."), onClick: () => store.splitTerminal(pane.id, "column") },
    ...(shown
      ? [{ label: t("Open in external terminal"), tip: t("Opens the current folder ({0}) in a new Windows Terminal window.", displayPath(shown.directory)), onClick: () => void ipc.openTerminal(shown.directory) }]
      : []),
    ...(compact && corner ? ["divider" as const, { label: t("Hide terminal"), shortcut: "Ctrl+`", onClick: hide }] : []),
  ];
  return (
    <div className="term-bar">
      <div className="term-tabs" role="tablist" aria-label={t("Terminals")}>
        {visible.map((i) => (
          <TermTab key={tabs[i].id} term={tabs[i]} n={number(tabs[i])} on={tabs[i] === shown} store={store} />
        ))}
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
