import type { ReactNode } from "react";
import {
  Archive,
  Users,
  GitBranch,
  Settings2,
  CalendarDays,
  CheckSquare,
  Columns3,
  LayoutDashboard,
  List,
  Search,
  X,
} from "lucide-react";
import type { HubProjectField } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
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
export function ProjectWorkspaceControls({
  layout,
  setLayout,
  selecting,
  setSelecting,
  endSelection,
  rowsCount,
  total,
  selectedView,
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
  assigned = 0,
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
  rowsCount: number;
  total: number;
  selectedView: boolean;
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
  assigned?: number;
  localRepository?: string;
  focusMine?: () => void;
  focusRepository?: () => void;
  settingsControls?: ReactNode;
  sharedControls?: ReactNode;
}) {
  const totalFilters = projectFilterCount(filters);
  const updateFilter = <K extends keyof ProjectFilters>(
    key: K,
    value: ProjectFilters[K],
  ) => setFilters((current) => ({ ...current, [key]: value }));
  return (
    <div className="project-controls">
      <nav className="project-toolbar" aria-label={t("Project navigation")}>
        <div
          className="project-view-switch"
          role="group"
          aria-label={t("Project view")}
        >
          {!gitlab && (
            <>
              <Button
                size="small"
                kind={layout === "overview" ? "primary" : undefined}
                onClick={() => setLayout("overview")}
              >
                <LayoutDashboard size={14} />
                {t("Overview")}
              </Button>
              <Button
                size="small"
                kind={layout === "calendar" ? "primary" : undefined}
                onClick={() => setLayout("calendar")}
              >
                <CalendarDays size={14} />
                {t("Calendar")}
              </Button>
            </>
          )}
          <Button
            size="small"
            kind={layout === "board" ? "primary" : undefined}
            onClick={() => setLayout("board")}
          >
            <Columns3 size={14} />
            {t("Board")}
          </Button>
          <Button
            size="small"
            kind={layout === "list" ? "primary" : undefined}
            onClick={() => setLayout("list")}
          >
            <List size={14} />
            {t("List")}
          </Button>
          {!gitlab && (
            <Button
              size="small"
              kind={layout === "timeline" ? "primary" : undefined}
              onClick={() => setLayout("timeline")}
            >
              <CalendarDays size={14} />
              {t("Timeline")}
            </Button>
          )}
        </div>
        <span className="project-visible-count">
          {t("{0} of {1} loaded items", rowsCount, total)}
          {layout === "list" && !selectedView ? ` · ${t("Project order")}` : ""}
        </span>
      </nav>
      <div className="project-filters">
        <label className="project-search">
          <Search size={14} />
          <input
            aria-label={t("Search project items")}
            placeholder={t("Search tasks, labels, or people…")}
            value={filters.query}
            onChange={(event) => updateFilter("query", event.target.value)}
          />
        </label>
        {!gitlab && !localProject && (
          <select
            className="select"
            aria-label={t("Item type")}
            value={filters.kind}
            onChange={(event) => updateFilter("kind", event.target.value)}
          >
            <option value="">{t("All types")}</option>
            <option value="issue">{t("Issues")}</option>
            <option value="pullRequest">{t("Pull requests")}</option>
            <option value="draft">{t("Drafts")}</option>
          </select>
        )}
        {repositories.length > 0 && (
          <select
            className="select"
            aria-label={t("Repository filter")}
            value={filters.repository}
            onChange={(event) => updateFilter("repository", event.target.value)}
          >
            <option value="">{t("All repositories")}</option>
            {[
              ...new Set([
                ...repositories,
                ...(filters.repository ? [filters.repository] : []),
              ]),
            ].map((repository) => (
              <option key={repository} value={repository}>
                {repository}
              </option>
            ))}
          </select>
        )}
        {people.length > 0 && (
          <select
            className="select"
            aria-label={t("Assignee filter")}
            value={filters.assignee}
            onChange={(event) => updateFilter("assignee", event.target.value)}
          >
            <option value="">{t("All assignees")}</option>
            {[
              ...new Set([
                ...people,
                ...(filters.assignee ? [filters.assignee] : []),
              ]),
            ].map((person) => (
              <option key={person} value={person}>
                @{person}
              </option>
            ))}
          </select>
        )}
        {me && (
          <button
            className={`project-filter-toggle ${filters.assignee === me ? "active" : ""}`}
            onClick={focusMine}
          >
            <Users size={13} />
            {t("Assigned to me")}
            <b>{assigned}</b>
          </button>
        )}
        {localRepository && (
          <button
            className={`project-filter-toggle ${filters.repository === localRepository ? "active" : ""}`}
            onClick={focusRepository}
          >
            <GitBranch size={13} />
            {t("Local repository")}
          </button>
        )}
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
          <>
            <Button
              size="small"
              kind={selecting ? "primary" : undefined}
              onClick={() => (selecting ? endSelection() : setSelecting(true))}
            >
              <CheckSquare size={13} />
              {t("Select items")}
            </Button>
          </>
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
        {!gitlab && (
          <button
            className={`project-filter-toggle ${filters.archived ? "active" : ""}`}
            aria-pressed={filters.archived}
            onClick={() => updateFilter("archived", !filters.archived)}
          >
            <Archive size={13} />
            {t("Include archived")}
          </button>
        )}
        {totalFilters > 0 && (
          <Button
            size="small"
            tip={t("Clear filters")}
            onClick={() => setFilters(emptyProjectFilters)}
          >
            <X size={13} />
            {t("Clear")}
          </Button>
        )}
      </div>
    </div>
  );
}
