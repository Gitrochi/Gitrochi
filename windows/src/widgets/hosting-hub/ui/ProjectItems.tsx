import { useEffect, useState, type CSSProperties } from "react";
import {
  Archive,
  CheckCircle2,
  CheckSquare,
  Square,
  Circle,
  FileText,
  Filter,
  GitPullRequest,
  Plus,
} from "lucide-react";
import {
  hubProjectColumns,
  type HubDetail,
  type HubProjectField,
  type HubProjectRow,
  type ProjectScheduleFields,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import {
  projectFieldValue,
  projectKind,
  projectRepository,
  type ProjectAsk,
} from "../lib/project-workspace";
import { ProjectColumnComposer } from "./ProjectColumnComposer";
import { ProjectCardMetadata, projectOptionTone } from "./ProjectCardMetadata";
import { ProjectRoadmap } from "./ProjectRoadmap";
const kindLabel = (row: HubProjectRow) =>
  row.id.startsWith("local-task:") ? t("Task") : projectKind(row) === "pullRequest"
    ? t("Pull request")
    : projectKind(row) === "draft"
      ? t("Draft")
      : projectKind(row) === "redacted"
        ? t("Restricted item")
        : t("Issue");
function TaskIcon({ row }: { row: HubProjectRow }) {
  return projectKind(row) === "pullRequest" ? (
    <GitPullRequest size={15} />
  ) : projectKind(row) === "draft" ? (
    <FileText size={15} />
  ) : /closed|merged/i.test(row.state ?? "") ? (
    <CheckCircle2 size={15} />
  ) : (
    <Circle size={15} />
  );
}
export function ProjectItems({
  layout,
  detail,
  fields,
  field,
  rows,
  selectedID,
  select,
  locked,
  add,
  open,
  safe,
  selecting = false,
  selectedIDs = new Set(),
  toggleSelection,
  visibleFieldIDs,
  scheduleFields,
  assignDate,
  ask,
  completedIDs = new Set<string>(),
}: {
  layout: "board" | "list" | "timeline";
  detail: HubDetail;
  fields: HubProjectField[];
  field?: HubProjectField;
  rows: HubProjectRow[];
  selectedID: string | null;
  select: (row: HubProjectRow) => void;
  locked: boolean;
  add: () => void;
  open: (url: string) => void;
  safe: (url: string) => boolean;
  selecting?: boolean;
  selectedIDs?: Set<string>;
  toggleSelection?: (row: HubProjectRow) => void;
  visibleFieldIDs?: string[];
  scheduleFields?: ProjectScheduleFields;
  assignDate?: (row: HubProjectRow, date: string) => Promise<boolean>;
  ask?: ProjectAsk;
  completedIDs?: Set<string>;
}) {
  const [composingColumn, setComposingColumn] = useState<string | null>(null);
  useEffect(() => setComposingColumn(null), [detail.item.id, field?.id, layout]);
  const localProject = detail.item.data.localProject === true;
  const columns = hubProjectColumns({ ...detail, fields, rows }, field?.id);
  const tableFields: HubProjectField[] =
    visibleFieldIDs !== undefined
      ? visibleFieldIDs.flatMap((id) => {
          const field = detail.fields.find((field) => field.id === id);
          return field && !/^title$/i.test(field.name) ? [field] : [];
        })
      : detail.item.data.localProject === true
        ? ["local-status", "local-priority", "local-due", "local-assignees"]
          .flatMap((id) => detail.fields.find((field) => field.id === id) ?? [])
        : [
          ...(field ? [field] : []),
          { id: "__repository", name: t("Repository"), options: [] },
          { id: "__assignees", name: t("Assignees"), options: [] },
        ];
  const rawFieldText = (row: HubProjectRow, value: HubProjectField) =>
    /^repository$/i.test(value.name) || value.id === "__repository"
      ? projectRepository(row) || "—"
      : /^assignees$/i.test(value.name) || value.id === "__assignees"
        ? row.assignees?.map((name) => `@${name}`).join(", ") || "—"
        : (value.options.find(
            (option) => option.id === projectFieldValue(row, value),
          )?.name ??
          (projectFieldValue(row, value) || "—"));
  const fieldText = (row: HubProjectRow, value: HubProjectField) => {
    const text = rawFieldText(row, value);
    return localProject && value.options.length ? t(text) : text;
  };
  const tableStyle = {
    gridTemplateColumns: `minmax(240px,2fr) ${tableFields.length ? `repeat(${tableFields.length},minmax(120px,1fr))` : ""}`,
    minWidth: 240 + tableFields.length * 134,
  };
  const activate = (row: HubProjectRow) =>
    selecting ? toggleSelection?.(row) : select(row);
  const card = (row: HubProjectRow) => (
    <button
      className={`project-card ${(selecting ? selectedIDs.has(row.id) : selectedID === row.id) ? "selected" : ""}`}
      key={row.id}
      onClick={() => activate(row)}
      aria-pressed={selecting ? selectedIDs.has(row.id) : selectedID === row.id}
    >
      {selecting && (
        <span className="project-card-check">
          {selectedIDs.has(row.id) ? (
            <CheckSquare size={14} />
          ) : (
            <Square size={14} />
          )}
        </span>
      )}
      <span className="project-card-meta">
        <span>
          <TaskIcon row={row} />
          {projectRepository(row) || kindLabel(row)}{" "}
          {row.number ? `#${row.number}` : ""}
        </span>
        {row.archived && <Archive size={12} />}
      </span>
      <strong className="project-card-title">{row.title}</strong>
      {row.body && <span className="project-card-description">{row.body}</span>}
      <ProjectCardMetadata row={row} detail={detail} group={field} scheduleFields={scheduleFields} completed={completedIDs.has(row.id)} />
    </button>
  );
  return (
    <>
      {layout === "board" ? (
        <div className="project-board" aria-label={t("Project board")}>
          {columns.map((column) => (
            <section
              className="project-column"
              key={column.id}
              style={
                {
                  "--project-color": field ? `var(--${projectOptionTone(field, column.id) === "neutral" ? "text-3" : projectOptionTone(field, column.id)})` : "var(--text-3)",
                } as CSSProperties
              }
            >
              <header>
                <span className="project-status-dot" />
                <strong>{localProject ? t(column.title) : column.title}</strong>
                <span className="project-count">{column.rows.length}</span>
                <Button
                  size="small"
                  tip={t(ask ? "Add task" : "Add item")}
                  aria-label={t(ask ? "Add task" : "Add item")}
                  disabled={locked}
                  onClick={() => ask ? setComposingColumn(column.id) : add()}
                >
                  <Plus size={13} />
                </Button>
              </header>
              <div className="project-column-cards">
                {column.rows.map(card)}
                {!column.rows.length && <div className="project-column-empty">{t("No tasks yet")}</div>}
                {ask ? <ProjectColumnComposer key={`${detail.item.id}:${field?.id ?? ""}:${column.id}`} detail={detail} field={field} option={column.id || undefined} ask={ask} locked={locked}
                  active={composingColumn === column.id} start={() => setComposingColumn(column.id)} close={() => setComposingColumn(null)} /> : (
                  <button className="project-column-add" disabled={locked} onClick={add}><Plus size={13} />{t("Add item")}</button>
                )}
              </div>
            </section>
          ))}
        </div>
      ) : layout === "list" ? (
        <div
          className="project-list"
          role="table"
          aria-label={t("Project items")}
        >
          <div className="project-table-head" role="row" style={tableStyle}>
            <span role="columnheader">{t("Title")}</span>
            {tableFields.map((value) => (
              <span role="columnheader" key={value.id}>
                {localProject ? t(value.name) : value.name}
              </span>
            ))}
          </div>
          {rows.map((row) => (
            <button
              role="row"
              style={tableStyle}
              className={`project-table-row ${(selecting ? selectedIDs.has(row.id) : selectedID === row.id) ? "selected" : ""}`}
              key={row.id}
              onClick={() => activate(row)}
            >
              <span className="project-table-title" role="cell">
                {selecting &&
                  (selectedIDs.has(row.id) ? (
                    <CheckSquare size={14} />
                  ) : (
                    <Square size={14} />
                  ))}
                <TaskIcon row={row} />
                <span>
                  <strong>{row.title}</strong>
                  <small>
                    {kindLabel(row)} {row.number ? `#${row.number}` : ""}
                  </small>
                </span>
              </span>
              {tableFields.map((value) => (
                <span role="cell" key={value.id}>
                  {value.options.length ? (
                    <span className="project-tag">{fieldText(row, value)}</span>
                  ) : (
                    fieldText(row, value)
                  )}
                </span>
              ))}
            </button>
          ))}
          {!rows.length && (
            <div className="project-canvas-empty">
              <Filter size={24} />
              <strong>{t("No matching items")}</strong>
              <span>
                {t("Clear filters or add the first task to this project.")}
              </span>
            </div>
          )}
        </div>
      ) : (
        <ProjectRoadmap
          detail={detail}
          rows={rows}
          selectedID={selectedID}
          select={activate}
          open={open}
          safe={safe}
          scheduleFields={scheduleFields}
          assignDate={assignDate}
          locked={locked}
        />
      )}
    </>
  );
}
