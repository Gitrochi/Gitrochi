import { ListFilter } from "@/shared/icons";
import { ChevronDown } from "@/shared/icons";
import { type LedgerStore, verdictCounts, verdictLook } from "@/entities/ledger";
import { basename } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, type MenuItem, showMenuBelow } from "@/shared/ui";

function FilterInput({ store }: { store: LedgerStore }) {
  return (
    <div className="ledger-filter-input">
      <ListFilter size={14} />
      <input className="input" value={store.filterText} placeholder={t("Filter sessions")} aria-label={t("Filter sessions")} onChange={(e) => { store.filterText = e.target.value; store.changed(); }} onKeyDown={(e) => { if (e.key === "Escape" && store.filterText) { e.stopPropagation(); store.filterText = ""; store.changed(); } }} />
    </div>
  );
}

/** Compact filters below the view tabs, leaving the app's page list as the only navigation column. */
export function LedgerTopBar({ store, repoPath }: { store: LedgerStore; repoPath: string | null }) {
  useObserve(store);
  const state = store.state!;
  const verdicts = verdictCounts(state.sessions, store.project).filter((c) => c.count || store.verdicts.has(c.verdict));
  const selected = store.verdicts.size === 1 ? [...store.verdicts][0] : null;
  const label = selected ? t(verdictLook(selected).label) : t(store.verdicts.size ? "Verdicts" : "All verdicts");
  const showVerdicts = (anchor: HTMLElement) => {
    const items: MenuItem[] = [
      { label: t("All verdicts"), checked: store.verdicts.size === 0, onClick: () => { store.verdicts.clear(); store.setView("board"); store.changed(); } },
      "divider",
      ...verdicts.map(({ verdict, count }) => {
        const look = verdictLook(verdict);
        return { label: t(look.label), checked: store.verdicts.has(verdict), shortcut: String(count), tip: t(look.hint), onClick: () => store.showVerdict(verdict) };
      }),
    ];
    showMenuBelow(anchor, items);
  };
  // Without a repository, the default repository scope means all projects.
  const choice = store.projectChoice === "repository" && !repoPath ? "all" : store.projectChoice;
  return (
    <div className="ledger-topbar" role="toolbar" aria-label={t("Ledger filters")}>
      <select className="select" aria-label={t("Project")} data-project={choice} value={choice} onChange={(e) => store.setProjectChoice(e.target.value)}>
        <option value="repository" disabled={!repoPath}>{repoPath ? t("This repository ({0})", basename(repoPath)) : t("This repository")}</option>
        <option value="all">{t("All projects")}</option>
        {state.projects.map((p) => <option key={p.key} value={p.key}>{p.name}</option>)}
      </select>
      <FilterInput store={store} />
      <Button size="small" className="ledger-verdict-menu" aria-label={`${t("Verdicts")}: ${label}`} aria-haspopup="menu" data-verdict={selected ?? "all"} onClick={(e) => showVerdicts(e.currentTarget)}>
        <span>{label}</span><ChevronDown size={12} />
      </Button>
    </div>
  );
}
