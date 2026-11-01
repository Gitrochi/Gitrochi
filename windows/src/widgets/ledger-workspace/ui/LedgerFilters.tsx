import { FolderGit2, Layers, ListFilter } from "lucide-react";
import type { CSSProperties } from "react";
import { type LedgerStore, verdictCounts, verdictLook } from "@/entities/ledger";
import { basename } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { verdictIcon } from "./parts";

function FilterInput({ store }: { store: LedgerStore }) {
  return (
    <div className="ledger-filter-input">
      <ListFilter size={14} />
      <input className="input" value={store.filterText} placeholder={t("Filter sessions")} aria-label={t("Filter sessions")} onChange={(e) => { store.filterText = e.target.value; store.changed(); }} onKeyDown={(e) => { if (e.key === "Escape" && store.filterText) { e.stopPropagation(); store.filterText = ""; store.changed(); } }} />
    </div>
  );
}

/**
 * The left column: a filter that narrows the lists (it does not search; Ctrl+K does), the project — the open
 * repository's by default — and the verdicts with their counts, which open the Board on that verdict.
 * (macOS: Views/Ledger/LedgerWorkspaceView.swift, filter column)
 */
export function LedgerFilters({ store, repoPath }: { store: LedgerStore; repoPath: string | null }) {
  useObserve(store);
  const state = store.state!;
  const counts = verdictCounts(state.sessions, store.project).filter((c) => c.count);
  // without a repository, "This repository" means every project
  const choice = store.projectChoice === "repository" && !repoPath ? "all" : store.projectChoice;
  const repoProject = store.repositoryProject;
  const item = (key: string, label: string, icon: React.ReactNode, count: number | null, disabled = false, tip?: string) => (
    <button key={key} type="button" className={`ledger-nav-item${choice === key ? " selected" : ""}`} aria-pressed={choice === key} disabled={disabled} data-project={key} data-tip={tip} onClick={() => store.setProjectChoice(key)}>
      {icon}
      <span className="grow">{label}</span>
      {count !== null && <span className="ledger-nav-count">{count}</span>}
    </button>
  );
  const open = (key: string | null) => state.projects.filter((p) => !key || p.key === key).reduce((n, p) => n + p.open, 0);
  return (
    <nav className="ledger-filters" aria-label={t("Ledger filters")}>
      <FilterInput store={store} />
      <div className="ledger-group-title">{t("Project")}</div>
      {item("repository", repoPath ? t("This repository ({0})", basename(repoPath)) : t("This repository"), <FolderGit2 size={15} />, repoProject ? open(repoProject) : null, !repoPath, repoPath && !repoProject ? t("No session belongs to this repository yet.") : undefined)}
      {item("all", t("All projects"), <Layers size={15} />, open(null))}
      {state.projects.map((p) => item(p.key, p.name, <span className="ledger-id-dot" style={{ background: "var(--text-3)" }} />, p.open))}
      <div className="ledger-group-title">{t("Verdicts")}</div>
      {!counts.length && <span className="hint" style={{ padding: "2px 10px" }}>{t("No sessions")}</span>}
      {counts.map(({ verdict, count }) => {
        const look = verdictLook(verdict), Icon = verdictIcon(verdict);
        const on = store.view === "board" && store.verdicts.size === 1 && store.verdicts.has(verdict);
        return (
          <button key={verdict} type="button" className={`ledger-nav-item${on ? " selected" : ""}`} data-verdict={verdict} data-tip={`${t(look.label)}|${t(look.hint)}`} onClick={() => store.showVerdict(verdict)}>
            <Icon size={15} style={{ color: `var(${look.color})` } as CSSProperties} />
            <span className="grow">{t(look.label)}</span>
            <span className="ledger-nav-count">{count}</span>
          </button>
        );
      })}
    </nav>
  );
}

/** The narrow window's filters: the project and the filter in one row above the view */
export function LedgerTopBar({ store, repoPath }: { store: LedgerStore; repoPath: string | null }) {
  useObserve(store);
  const state = store.state!;
  return (
    <div className="ledger-topbar">
      <select className="select" aria-label={t("Project")} value={store.projectChoice} onChange={(e) => store.setProjectChoice(e.target.value)}>
        <option value="repository" disabled={!repoPath}>{repoPath ? t("This repository ({0})", basename(repoPath)) : t("This repository")}</option>
        <option value="all">{t("All projects")}</option>
        {state.projects.map((p) => <option key={p.key} value={p.key}>{p.name}</option>)}
      </select>
      <FilterInput store={store} />
    </div>
  );
}
