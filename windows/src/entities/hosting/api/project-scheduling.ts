import { t } from "@/shared/i18n";
import { localProjects } from "../model/local-projects";
import { HostingError } from "./hosting";
import { ensureHubCurrent, hubUsesLocal, hubError, hubGraphql, HubUncertainWriteError, updateHubProjectField, type HubAccess, type HubDetail, type HubProjectRow } from "./hub";
import { resolveScheduleFields, scheduleReschedule, type ProjectScheduleSettings } from "../model/project-schedule";

/** macOS: ProjectScheduling.swift. A fresh comparison protects concurrent schedule edits. */
export async function rescheduleHubProjectItem(c: HubAccess, detail: HubDetail, row: HubProjectRow, settings: ProjectScheduleSettings, targetDay: string): Promise<void> {
  if (hubUsesLocal(c, detail.item)) { await localProjects.reschedule(detail, row, settings, targetDay); ensureHubCurrent(c); return; }
  ensureHubCurrent(c);
  const loaded = detail.rows.find((value) => value.id === row.id);
  if (c.target.provider !== "github" || !detail.item.id || !loaded || loaded.archived || loaded.kind === "redacted") throw new Error(t("Select a loaded project field and item."));
  let changes: ReturnType<typeof scheduleReschedule>;
  try { changes = scheduleReschedule(loaded, detail.fields, settings, targetDay); }
  catch (error) { throw new Error(t(error instanceof Error ? error.message : "Choose valid project date fields before scheduling this task.")); }
  const pending = changes.filter((change) => change.value !== (loaded.values?.[change.fieldID] ?? loaded.statuses[change.fieldID] ?? ""));
  if (!pending.length) return;
  const response = await hubGraphql<{ node?: { id?: string; isArchived?: boolean; project?: { id?: string }; fieldValues?: { nodes?: { date?: string; field?: { id?: string } }[]; pageInfo?: { hasNextPage?: boolean } } } }>(c, "query($id:ID!){node(id:$id){... on ProjectV2Item{id isArchived project{id} fieldValues(first:100){nodes{... on ProjectV2ItemFieldDateValue{date field{... on ProjectV2FieldCommon{id}}}} pageInfo{hasNextPage}}}}}", { id: loaded.id });
  const fresh = response.node, values = new Map(fresh?.fieldValues?.nodes?.map((value) => [value.field?.id, value.date ?? ""]));
  const selected = resolveScheduleFields(detail.fields, settings);
  const comparedIDs = [...new Set([selected.start?.id, selected.due?.id].filter((id): id is string => !!id))];
  if (fresh?.id !== loaded.id || fresh.project?.id !== detail.item.id || fresh.isArchived !== false || !Array.isArray(fresh.fieldValues?.nodes) || fresh.fieldValues?.pageInfo?.hasNextPage !== false || comparedIDs.some((id) => !detail.fields.some((field) => field.id === id && field.kind === "date") || (values.get(id) ?? "") !== (loaded.values?.[id] ?? loaded.statuses[id] ?? ""))) throw new Error(t("This item changed on the server. Refresh before saving."));
  let completed = 0;
  try {
    for (const change of pending) {
      const field = detail.fields.find((value) => value.id === change.fieldID)!;
      await updateHubProjectField(c, detail, loaded, field, change.value);
      completed++;
    }
  } catch (error) {
    if (!completed && error instanceof HostingError && error.status >= 400 && error.status < 500) throw error;
    throw new HubUncertainWriteError(`${hubError(error, c.token)}\n\n${t("The schedule may have changed. Refresh the project before scheduling again.")}`);
  }
}
