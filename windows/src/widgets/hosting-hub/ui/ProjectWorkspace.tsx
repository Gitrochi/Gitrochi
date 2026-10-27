import { useState } from "react";
import {
  Archive,
  ArrowRight,
  CalendarDays,
  Columns3,
  CheckSquare,
  GitBranch,
  List,
  Search,
  Target,
  Users,
  X,
} from "lucide-react";
import {
  type HubAccess,
  type HubDetail,
  type HubProjectRow,
  type HubProjectView,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import {
  filterProjectRows,
  emptyProjectFilters,
  projectFilterCount,
  type ProjectAsk,
  type ProjectLocalActions,
  projectRepository,
  projectSelectFields,
  type ProjectFilters,
} from "../lib/project-workspace";
import { ProjectInspector } from "./ProjectInspector";
import { ProjectComposer, type ProjectIssueLoader } from "./ProjectComposer";
import { ProjectItems } from "./ProjectItems";
import { ProjectHero } from "./ProjectHero";
import { ProjectSettings } from "./ProjectSettings";
import { ProjectSavedViews } from "./ProjectSavedViews";
import { ProjectBulkActions } from "./ProjectBulkActions";
import { useProjectViews } from "../model/use-project-views";
import "./project-workspace.css";

export function ProjectWorkspace({
  detail,
  locked,
  gitlab,
  open,
  safe,
  ask,
  local,
  loadIssues,
  me,
  readAccess,
}: {
  detail: HubDetail;
  locked: boolean;
  gitlab: boolean;
  open: (url: string) => void;
  safe: (url: string) => boolean;
  ask: ProjectAsk;
  local?: ProjectLocalActions;
  loadIssues?: ProjectIssueLoader;
  me?: string;
  readAccess?: () => Promise<HubAccess>;
}) {
  const [layout, setLayout] = useState<"board" | "list" | "timeline">("board"),
    [group, setGroup] = useState("");
  const [filters, setFilters] = useState(emptyProjectFilters),
    [selectedID, setSelectedID] = useState<string | null>(null),
    [composing, setComposing] = useState(false);
  const [settings, setSettings] = useState<
      "project" | "fields" | "views" | null
    >(null),
    [viewID, setViewID] = useState(""),
    [selecting, setSelecting] = useState(false),
    [selectedIDs, setSelectedIDs] = useState<Set<string>>(new Set());
  const shared = useProjectViews(detail, gitlab ? undefined : readAccess),
    selectedView = shared.views.find((view) => view.id === viewID);
  const chooseView = (view?: HubProjectView) => {
    setViewID(view?.id ?? "");
    if (view) {
      setLayout(
        view.layout === "TABLE_LAYOUT"
          ? "list"
          : view.layout === "ROADMAP_LAYOUT"
            ? "timeline"
            : "board",
      );
      setGroup(view.groupFieldIDs[0] ?? "");
      setFilters(emptyProjectFilters);
    }
  };
  const endSelection = () => {
    setSelecting(false);
    setSelectedIDs(new Set());
  };
  const fields = projectSelectFields(detail),
    field =
      fields.find((value) => value.id === group) ??
      fields.find((value) => /^(status|상태)$/i.test(value.name)) ??
      fields[0];
  const rows = filterProjectRows(detail.rows, filters),
    selected = detail.rows.find((row) => row.id === selectedID);
  const repositories = [
      ...new Set(detail.rows.map(projectRepository).filter(Boolean)),
    ].sort(),
    people = [
      ...new Set(detail.rows.flatMap((row) => row.assignees ?? [])),
    ].sort();
  const activeRows = detail.rows.filter((row) => !row.archived),
    assigned = me
      ? activeRows.filter((row) =>
          row.assignees?.some(
            (name) => name.toLocaleLowerCase() === me.toLocaleLowerCase(),
          ),
        ).length
      : 0;
  const totalFilters = projectFilterCount(filters);
  const updateFilter = <K extends keyof ProjectFilters>(
    key: K,
    value: ProjectFilters[K],
  ) => setFilters((current) => ({ ...current, [key]: value }));
  const select = (row: HubProjectRow) => {
    setSelectedID(row.id);
    setComposing(false);
  };
  return (
    <div className="project-workspace">
      <ProjectHero
        detail={detail}
        gitlab={gitlab}
        locked={locked}
        open={open}
        safe={safe}
        add={() => setComposing(true)}
        settings={() => setSettings("project")}
      />
      <div className="project-focus">
        <span>
          <Target size={14} />
          {t("Focus")}
        </span>
        <button
          className={filters.assignee === me && !!me ? "active" : ""}
          disabled={!me}
          onClick={() =>
            updateFilter("assignee", filters.assignee === me ? "" : (me ?? ""))
          }
        >
          <Users size={13} />
          {t("Assigned to me")}
          <b>{assigned}</b>
        </button>
        {local?.repository && (
          <button
            className={filters.repository === local.repository ? "active" : ""}
            onClick={() =>
              updateFilter(
                "repository",
                filters.repository === local.repository ? "" : local.repository,
              )
            }
          >
            <GitBranch size={13} />
            {local.repository}
          </button>
        )}
        <span className="project-focus-hint">
          {t("Select a task to inspect fields and start work.")}
        </span>
      </div>
      {!gitlab && (
        <ProjectSavedViews
          views={shared.views}
          loading={shared.loading}
          error={shared.error}
          selected={selectedView}
          choose={chooseView}
          manage={() => setSettings("views")}
          open={open}
          projectURL={detail.item.url}
        />
      )}
      <div className="project-controls">
        <div className="project-toolbar">
          <div
            className="project-view-switch"
            role="group"
            aria-label={t("Project view")}
          >
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
          <Button
            size="small"
            kind={selecting ? "primary" : undefined}
            onClick={() => (selecting ? endSelection() : setSelecting(true))}
          >
            <CheckSquare size={13} />
            {t("Select items")}
          </Button>
          <span className="project-visible-count">
            {t("{0} of {1} loaded items", rows.length, detail.rows.length)}
            {layout === "list" && !selectedView
              ? ` · ${t("Project order")}`
              : ""}
          </span>
          {layout !== "timeline" && !!fields.length && (
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
                    {value.name}
                  </option>
                ))}
              </select>
            </label>
          )}
        </div>
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
          {!gitlab && (
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
              onChange={(event) =>
                updateFilter("repository", event.target.value)
              }
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
      {selecting && (
        <ProjectBulkActions
          detail={detail}
          rows={detail.rows.filter((row) => selectedIDs.has(row.id))}
          visible={rows.length}
          gitlab={gitlab}
          locked={locked}
          ask={ask}
          selectAll={() => setSelectedIDs(new Set(rows.map((row) => row.id)))}
          done={endSelection}
        />
      )}
      {settings && (
        <ProjectSettings
          key={settings}
          initialTab={settings}
          detail={detail}
          locked={locked}
          ask={ask}
          close={() => setSettings(null)}
          views={shared.views}
          viewLoading={shared.loading}
          viewError={shared.error}
          reloadViews={shared.reload}
          moreViews={shared.more}
          loadMoreViews={shared.loadMore}
          open={open}
          safe={safe}
        />
      )}
      {detail.notice && (
        <div className="project-inline-notice" role="status">
          {detail.notice}
        </div>
      )}
      {composing && (
        <ProjectComposer
          detail={detail}
          locked={locked}
          gitlab={gitlab}
          ask={ask}
          close={() => setComposing(false)}
          loadIssues={loadIssues}
        />
      )}
      <div className={`project-body ${selected ? "has-inspector" : ""}`}>
        <div className="project-canvas">
          <ProjectItems
            layout={layout}
            detail={detail}
            fields={fields}
            field={field}
            rows={rows}
            selectedID={selectedID}
            select={select}
            locked={locked}
            add={() => setComposing(true)}
            open={open}
            safe={safe}
            selecting={selecting}
            selectedIDs={selectedIDs}
            toggleSelection={(row) =>
              setSelectedIDs((current) => {
                const next = new Set(current);
                if (next.has(row.id)) next.delete(row.id);
                else next.add(row.id);
                return next;
              })
            }
            visibleFieldIDs={selectedView?.visibleFieldIDs}
          />
          {!detail.rows.length && layout === "board" && (
            <div className="project-first-task">
              <Target size={18} />
              <div>
                <strong>{t("Make room for your next idea")}</strong>
                <span>
                  {t(
                    "Your real project columns are ready. Add a draft or choose a repository issue.",
                  )}
                </span>
              </div>
              <Button
                size="small"
                disabled={locked}
                onClick={() => setComposing(true)}
              >
                {t("Add the first task")}
                <ArrowRight size={13} />
              </Button>
            </div>
          )}
        </div>
        {selected && (
          <ProjectInspector
            key={selected.id}
            detail={detail}
            row={selected}
            locked={locked}
            gitlab={gitlab}
            open={open}
            safe={safe}
            ask={ask}
            close={() => setSelectedID(null)}
            local={local}
            onMoved={() => {
              setLayout("list");
              setViewID("");
            }}
          />
        )}
      </div>
    </div>
  );
}
