import type { ReactNode } from "react";
import { Settings2 } from "lucide-react";
import { CheckSquare, ListFilter } from "@/shared/icons";
import { Search } from "@/shared/icons";
import type { HubProjectField } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button, type MenuItem, showMenuBelow, StatusPill } from "@/shared/ui";
import {
  emptyProjectFilters,
  projectFilterCount,
  type ProjectFilters,
} from "../lib/project-workspace";
export type ProjectLayout =
  | "overview"
  | "calendar"
  | "board"
  | "list"
  | "timeline";
/** The layouts as the redesign's Projects board names them. macOS calls the last two "table" and "roadmap" too. */
const tabs: { id: ProjectLayout; label: string; planning?: boolean }[] = [
  { id: "overview", label: "Overview", planning: true },
  { id: "calendar", label: "Calendar", planning: true },
  { id: "board", label: "Board" },
  { id: "list", label: "Table" },
  { id: "timeline", label: "Roadmap", planning: true },
];
/**
 * Underline tabs for the layouts, then one row with the search field and Filter, as the redesign's Projects board draws
 * them. What the page already offered (grouping, selection, schedule setup, shared views) follows on the same row.
 */
export function ProjectWorkspaceControls({
  layout,
  setLayout,
  selecting,
  setSelecting,
  endSelection,
  fields,
  field,
  setGroup,
  filters,
  setFilters,
  gitlab,
  repositories,
  people,
  localProject = false,
  me,
  localRepository,
  focusMine,
  focusRepository,
  settingsControls,
  sharedControls,
}: {
  layout: ProjectLayout;
  setLayout: (value: ProjectLayout) => void;
  selecting: boolean;
  setSelecting: (value: boolean) => void;
  endSelection: () => void;
  fields: HubProjectField[];
  field?: HubProjectField;
  setGroup: (value: string) => void;
  filters: ProjectFilters;
  setFilters: (
    value: ProjectFilters | ((current: ProjectFilters) => ProjectFilters),
  ) => void;
  gitlab: boolean;
  repositories: string[];
  people: string[];
  localProject?: boolean;
  me?: string;
  localRepository?: string;
  focusMine?: () => void;
  focusRepository?: () => void;
  settingsControls?: ReactNode;
  sharedControls?: ReactNode;
}) {
  // The search has its own field; the pill on Filter counts what the menu holds.
  const totalFilters = projectFilterCount({ ...filters, query: "" });
  const updateFilter = <K extends keyof ProjectFilters>(
    key: K,
    value: ProjectFilters[K],
  ) => setFilters((current) => ({ ...current, [key]: value }));
  const choice = (key: "kind" | "repository" | "assignee", value: string, label: string): MenuItem =>
    ({ label, checked: filters[key] === value, onClick: () => updateFilter(key, value) });
  const filterMenu = (): MenuItem[] => [
    ...(!gitlab && !localProject ? [{ label: t("Item type"), submenu: [choice("kind", "", t("All types")), choice("kind", "issue", t("Issues")), choice("kind", "pullRequest", t("Pull requests")), choice("kind", "draft", t("Drafts"))] }] : []),
    ...(repositories.length ? [{ label: t("Repository filter"), submenu: [choice("repository", "", t("All repositories")), ...[...new Set([...repositories, ...(filters.repository ? [filters.repository] : [])])].map((repository) => choice("repository", repository, repository))] }] : []),
    ...(people.length ? [{ label: t("Assignee filter"), submenu: [choice("assignee", "", t("All assignees")), ...[...new Set([...people, ...(filters.assignee ? [filters.assignee] : [])])].map((person) => choice("assignee", person, `@${person}`))] }] : []),
    ...(me && focusMine ? [{ label: t("Assigned to me"), checked: filters.assignee === me, onClick: focusMine }] : []),
    ...(localRepository && focusRepository ? [{ label: t("Local repository"), checked: filters.repository === localRepository, onClick: focusRepository }] : []),
    ...(!gitlab ? [{ label: t("Include archived"), checked: filters.archived, onClick: () => updateFilter("archived", !filters.archived) }] : []),
    "divider",
    { label: t("Clear filters"), disabled: !totalFilters, onClick: () => setFilters((current) => ({ ...emptyProjectFilters, query: current.query })) },
  ];
  return (
    <div className="project-controls">
      <nav className="project-tabs" aria-label={t("Project views")}>
        {tabs.filter((tab) => !gitlab || !tab.planning).map((tab) => (
          <button
            type="button"
            key={tab.id}
            className={layout === tab.id ? "on" : ""}
            aria-current={layout === tab.id ? "page" : undefined}
            onClick={() => setLayout(tab.id)}
          >
            {t(tab.label)}
          </button>
        ))}
      </nav>
      <div className="project-filters">
        <label className="project-search">
          <Search size={13} />
          <input
            aria-label={t("Search tasks")}
            placeholder={t("Search tasks")}
            value={filters.query}
            onChange={(event) => updateFilter("query", event.target.value)}
          />
        </label>
        <Button aria-haspopup="menu" onClick={(event) => showMenuBelow(event.currentTarget, filterMenu())}>
          <ListFilter size={13} />
          {t("Filter")}
          {totalFilters > 0 && <StatusPill tone="neutral">{totalFilters}</StatusPill>}
        </Button>
        {(layout === "board" || layout === "list") && !!fields.length && (
          <label className="project-group">
            <span>{t("Group by")}</span>
            <select
              className="select"
              aria-label={t("Group by")}
              value={field?.id}
              onChange={(event) => setGroup(event.target.value)}
            >
              {fields.map((value) => (
                <option key={value.id} value={value.id}>
                  {localProject ? t(value.name) : value.name}
                </option>
              ))}
            </select>
          </label>
        )}
        {(layout === "board" || layout === "list") && (
          <Button
            aria-pressed={selecting}
            className={selecting ? "pressed" : ""}
            onClick={() => (selecting ? endSelection() : setSelecting(true))}
          >
            <CheckSquare size={13} />
            {t("Select items")}
          </Button>
        )}
        {settingsControls}
        {sharedControls && (
          <details className="project-shared-menu">
            <summary>
              <Settings2 size={13} />
              {t("Shared views")}
            </summary>
            <div>{sharedControls}</div>
          </details>
        )}
      </div>
    </div>
  );
}
