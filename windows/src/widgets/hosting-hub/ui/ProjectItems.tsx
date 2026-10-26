import type { CSSProperties } from "react";
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
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import {
  projectFieldValue,
  projectKind,
  projectRepository,
} from "../lib/project-workspace";
import { ProjectRoadmap } from "./ProjectRoadmap";
const colors = [
  "var(--text-3)",
  "var(--accent)",
  "var(--orange)",
  "var(--green)",
  "var(--red)",
];
const kindLabel = (row: HubProjectRow) =>
  projectKind(row) === "pullRequest"
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
}) {
  const columns = hubProjectColumns({ ...detail, fields, rows }, field?.id);
  const tableFields: HubProjectField[] =
    visibleFieldIDs !== undefined
      ? visibleFieldIDs.flatMap((id) => {
          const field = detail.fields.find((field) => field.id === id);
          return field && !/^title$/i.test(field.name) ? [field] : [];
        })
      : [
          ...(field ? [field] : []),
          { id: "__repository", name: t("Repository"), options: [] },
          { id: "__assignees", name: t("Assignees"), options: [] },
        ];
  const fieldText = (row: HubProjectRow, value: HubProjectField) =>
    /^repository$/i.test(value.name) || value.id === "__repository"
      ? projectRepository(row) || "—"
      : /^assignees$/i.test(value.name) || value.id === "__assignees"
        ? row.assignees?.map((name) => `@${name}`).join(", ") || "—"
        : (value.options.find(
            (option) => option.id === projectFieldValue(row, value),
          )?.name ??
          (projectFieldValue(row, value) || "—"));
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
      <span className="project-card-footer">
        <span className="project-labels">
          {(row.labels ?? []).slice(0, 2).map((label) => (
            <span className="project-tag" key={label}>
              {label}
            </span>
          ))}
          {fields
            .filter((value) => value.id !== field?.id && row.statuses[value.id])
            .slice(0, 1)
            .map((value) => (
              <span className="project-tag" key={value.id}>
                {
                  value.options.find(
                    (option) => option.id === row.statuses[value.id],
                  )?.name
                }
              </span>
            ))}
        </span>
        <span className="project-avatar-group">
          {row.assignees?.slice(0, 3).map((name) => (
            <span className="project-avatar" key={name} title={`@${name}`}>
              {name.slice(0, 1).toUpperCase()}
            </span>
          ))}
        </span>
      </span>
    </button>
  );
  return (
    <>
      {layout === "board" ? (
        <div className="project-board" aria-label={t("Project board")}>
          {columns.map((column, index) => (
            <section
              className="project-column"
              key={column.id}
              style={
                {
                  "--project-color": colors[index % colors.length],
                } as CSSProperties
              }
            >
              <header>
                <span className="project-status-dot" />
                <strong>{column.title}</strong>
                <span className="project-count">{column.rows.length}</span>
                <Button
                  size="small"
                  tip={t("Add item")}
                  disabled={locked}
                  onClick={() => add()}
                >
                  <Plus size={13} />
                </Button>
              </header>
              <div className="project-column-cards">
                {column.rows.map(card)}
                {!column.rows.length && (
                  <div className="project-column-empty">
                    <div className="project-empty-lines">
                      <i />
                      <i />
                      <i />
                    </div>
                    <span>{t("No items yet")}</span>
                    <button disabled={locked} onClick={() => add()}>
                      <Plus size={12} />
                      {t("Add item")}
                    </button>
                  </div>
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
                {value.name}
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
        />
      )}
    </>
  );
}
