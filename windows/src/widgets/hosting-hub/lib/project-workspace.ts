import { hubError, HubUncertainWriteError } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import type {
  HubAccess,
  HubDetail,
  HubProjectField,
  HubProjectRow,
} from "@/entities/hosting";

export interface ProjectFilters {
  query: string;
  kind: string;
  repository: string;
  assignee: string;
  archived: boolean;
}
export const projectKind = (row: HubProjectRow) =>
  row.kind ??
  (/\/pull\/|\/merge_requests\//.test(row.url)
    ? "pullRequest"
    : row.url
      ? "issue"
      : row.contentID
        ? "draft"
        : "redacted");
export function projectRepository(row: HubProjectRow): string {
  if (row.repository) return row.repository;
  try {
    return new URL(row.url).pathname
      .replace(/\/(?:-\/)?(?:issues|pull|merge_requests)\/\d+\/?$/, "")
      .replace(/^\//, "");
  } catch {
    return "";
  }
}
export const projectFieldValue = (row: HubProjectRow, field: HubProjectField) =>
  row.values?.[field.id] ?? row.statuses[field.id] ?? "";
export const projectSelectFields = (detail: HubDetail) =>
  detail.fields.filter(
    (field) =>
      field.kind === "singleSelect" ||
      (!field.kind && field.options.length > 0),
  );
export function filterProjectRows(
  rows: HubProjectRow[],
  filters: ProjectFilters,
): HubProjectRow[] {
  const query = filters.query.trim().toLocaleLowerCase();
  return rows.filter(
    (row) =>
      (filters.archived || !row.archived) &&
      (!filters.kind || projectKind(row) === filters.kind) &&
      (!filters.repository || projectRepository(row) === filters.repository) &&
      (!filters.assignee ||
        row.assignees?.some(
          (name) =>
            name.toLocaleLowerCase() === filters.assignee.toLocaleLowerCase(),
        )) &&
      (!query ||
        [
          row.title,
          row.body,
          projectRepository(row),
          ...(row.labels ?? []),
          ...(row.assignees ?? []),
        ]
          .join(" ")
          .toLocaleLowerCase()
          .includes(query)),
  );
}
export function projectBranchName(row: HubProjectRow): string {
  const title = row.title
    .toLocaleLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 54)
    .replace(/-$/, "");
  return `feature/${row.number ? `${row.number}-` : ""}${title || "project-task"}`;
}
export function projectDateRows(
  rows: HubProjectRow[],
  field: HubProjectField | undefined,
): { row: HubProjectRow; date: string }[] {
  if (!field) return [];
  return rows
    .map((row) => ({ row, date: projectFieldValue(row, field) }))
    .filter(
      (value) =>
        /^\d{4}-\d{2}-\d{2}$/.test(value.date) &&
        Number.isFinite(Date.parse(value.date)) &&
        new Date(value.date).toISOString().slice(0, 10) === value.date,
    )
    .sort((a, b) => a.date.localeCompare(b.date));
}

export function projectDateRange(
  row: HubProjectRow,
  startField?: HubProjectField,
  endField?: HubProjectField,
): {
  start: number;
  end: number;
  startText: string;
  endText: string;
  reversed: boolean;
} | null {
  const valid = (value: string) =>
    /^\d{4}-\d{2}-\d{2}$/.test(value) &&
    Number.isFinite(Date.parse(value)) &&
    new Date(value).toISOString().slice(0, 10) === value;
  const first = startField ? projectFieldValue(row, startField) : "",
    last = endField ? projectFieldValue(row, endField) : "";
  const startText = valid(first) ? first : valid(last) ? last : "",
    endText = valid(last) ? last : startText;
  if (!startText) return null;
  const start = Date.parse(startText),
    end = Date.parse(endText);
  return {
    start: Math.min(start, end),
    end: Math.max(start, end),
    startText,
    endText,
    reversed: start > end,
  };
}

export const emptyProjectFilters: ProjectFilters = {
  query: "",
  kind: "",
  repository: "",
  assignee: "",
  archived: false,
};
export const projectFilterCount = (filters: ProjectFilters) =>
  Object.values(filters).filter(Boolean).length;
export type ProjectAsk = ((
  title: string,
  body: string,
  action: (access: HubAccess) => Promise<unknown>,
) => void) & { cancel?: () => void };
export interface ProjectLocalActions {
  repository: string;
  host: string;
  path?: string | null;
  branches?: string[];
  onStartTask?: (row: HubProjectRow) => void;
  onOpenRequest?: (row: HubProjectRow) => void;
}

/** A failed batch must refresh before retrying because earlier rows may already have changed. */
export async function runProjectBatch(
  access: HubAccess,
  rows: HubProjectRow[],
  work: (access: HubAccess, row: HubProjectRow) => Promise<unknown>,
): Promise<void> {
  try {
    for (const row of rows) await work(access, row);
  } catch (error) {
    throw new HubUncertainWriteError(
      `${hubError(error, access.token)}\n\n${t("Some selected items may have changed. Refresh the project before trying again.")}`,
    );
  }
}
