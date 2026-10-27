import { useEffect, useState } from "react";
import { ArrowRight, Target } from "lucide-react";
import {
  resolveScheduleFields,
  scheduleEntries,
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
import {
  ProjectWorkspaceControls,
  type ProjectLayout,
} from "./ProjectWorkspaceControls";
import { useProjectSchedule } from "../model/use-project-schedule";
import { ProjectScheduleControls } from "./ProjectScheduleControls";
import { ProjectOverview } from "./ProjectOverview";
import { ProjectCalendar } from "./ProjectCalendar";
import "./project-workspace.css";
import "./project-schedule.css";
import "./project-compact.css";

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
  scheduleContext = "",
  focusRowID,
  onFocusConsumed,
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
  scheduleContext?: string;
  focusRowID?: string | null;
  onFocusConsumed?: (id: string) => void;
}) {
  const localProject = detail.item.data.localProject === true;
  const [layout, setLayout] = useState<ProjectLayout>(
      gitlab ? "board" : "overview",
    ),
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
  useEffect(() => {
    if (focusRowID && detail.rows.some((row) => row.id === focusRowID)) {
      setSelectedID(focusRowID);
      setSelecting(false);
      setComposing(false);
      onFocusConsumed?.(focusRowID);
    }
  }, [focusRowID, detail.item.id, detail.rows, onFocusConsumed]);
  const schedule = useProjectSchedule(detail, scheduleContext, ask),
    scheduleFields = resolveScheduleFields(detail.fields, schedule.settings);
  const shared = useProjectViews(
      detail,
      gitlab || localProject ? undefined : readAccess,
    ),
    selectedView = shared.views.find((view) => view.id === viewID);
  const chooseView = (view?: HubProjectView) => {
    setViewID(view?.id ?? "");
    if (view) {
      setSelecting(false);
      setSelectedIDs(new Set());
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
  const changeLayout = (value: ProjectLayout) => {
    setLayout(value);
    if (value !== "board" && value !== "list") endSelection();
  };
  const fields = projectSelectFields(detail),
    field =
      fields.find((value) => value.id === group) ??
      fields.find((value) => /^(status|상태)$/i.test(value.name)) ??
      fields[0];
  const rows = filterProjectRows(detail.rows, filters),
    entries = scheduleEntries(rows, detail.fields, schedule.settings),
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
        localProject={localProject}
        planning={layout === "overview" || layout === "calendar"}
        gitlab={gitlab}
        locked={locked}
        open={open}
        safe={safe}
        add={() => setComposing(true)}
        settings={() => setSettings("project")}
      />
      <ProjectWorkspaceControls
        localProject={localProject}
        me={me}
        assigned={assigned}
        localRepository={local?.repository}
        focusMine={() =>
          updateFilter("assignee", filters.assignee === me ? "" : (me ?? ""))
        }
        focusRepository={() =>
          updateFilter(
            "repository",
            filters.repository === local?.repository
              ? ""
              : (local?.repository ?? ""),
          )
        }
        settingsControls={
          !gitlab ? (
            <ProjectScheduleControls
              localProject={localProject}
              fields={detail.fields}
              settings={schedule.settings}
              change={schedule.changeSettings}
              manageFields={() => setSettings("fields")}
              locked={locked}
            />
          ) : undefined
        }
        sharedControls={
          !gitlab && !localProject ? (
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
          ) : undefined
        }
        layout={layout}
        setLayout={changeLayout}
        selecting={selecting}
        setSelecting={setSelecting}
        endSelection={endSelection}
        rowsCount={rows.length}
        total={detail.rows.length}
        selectedView={!!selectedView}
        fields={fields}
        field={field}
        setGroup={setGroup}
        filters={filters}
        setFilters={setFilters}
        gitlab={gitlab}
        repositories={repositories}
        people={people}
      />
      {schedule.error && <p className="project-inline-error error-text" role="alert">{schedule.error}</p>}
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
          {layout === "overview" ? (
            <ProjectOverview
              entries={entries}
              today={schedule.today}
              locked={locked}
              selectedID={selectedID}
              select={select}
              status={scheduleFields.status}
              complete={(row) => schedule.complete(row, locked)}
              completionEnabled={
                !locked && !schedule.busy &&
                !!scheduleFields.status?.options.some((value) =>
                  schedule.settings.completedOptionIDs.includes(value.id),
                )
              }
              localRepository={local?.repository}
              calendar={() => changeLayout("calendar")}
              add={() => setComposing(true)}
              manageFields={() => setSettings("fields")}
              hasDueField={!!scheduleFields.due}
              localProject={localProject}
              more={detail.more}
            />
          ) : layout === "calendar" ? (
            <ProjectCalendar
              entries={entries}
              today={schedule.today}
              status={scheduleFields.status}
              selectedID={selectedID}
              select={select}
              reschedule={schedule.reschedule}
              locked={locked}
              hasDateField={!!scheduleFields.due || !!scheduleFields.start}
              manageFields={() => setSettings("fields")}
            />
          ) : (
            <>
              <ProjectItems
                key={detail.item.id}
                layout={layout as "board" | "list" | "timeline"}
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
                scheduleFields={scheduleFields}
                assignDate={schedule.assignDate}
                ask={gitlab ? undefined : ask}
                completedIDs={new Set(entries.filter((entry) => entry.completed).map((entry) => entry.row.id))}
              />
            </>
          )}
          {!detail.rows.length && layout === "board" && (
            <div className="project-first-task">
              <Target size={18} />
              <div>
                <strong>{t("Make room for your next idea")}</strong>
                <span>
                  {t(
                    localProject
                      ? "Your local columns are ready. Add a task and give it a due date."
                      : "Your real project columns are ready. Add a draft or choose a repository issue.",
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
            readAccess={localProject ? undefined : readAccess}
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
