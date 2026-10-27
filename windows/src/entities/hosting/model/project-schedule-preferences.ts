import type { ProjectScheduleSettings } from "./project-schedule";
const key = (accountID: string, projectID: string) =>
  `gitrochi.project-schedule.v1:${projectID.startsWith("local:") ? "local" : accountID}:${projectID}`;
/** Only field identifiers are stored locally; credentials and task data stay out of preferences. */
export function readProjectScheduleSettings(
  accountID: string,
  projectID: string,
): ProjectScheduleSettings {
  try {
    const value: unknown = JSON.parse(
      localStorage.getItem(key(accountID, projectID)) ?? "null",
    );
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const saved = value as Partial<ProjectScheduleSettings>;
      if (!Array.isArray(saved.completedOptionIDs) || saved.completedOptionIDs.some(value => typeof value !== "string") || [saved.startFieldID, saved.dueFieldID, saved.statusFieldID].some(value => value !== undefined && typeof value !== "string")) throw new Error("Invalid schedule preferences");
      return {
        startFieldID:
          typeof saved.startFieldID === "string"
            ? saved.startFieldID
            : undefined,
        dueFieldID:
          typeof saved.dueFieldID === "string" ? saved.dueFieldID : undefined,
        statusFieldID:
          typeof saved.statusFieldID === "string"
            ? saved.statusFieldID
            : undefined,
        completedOptionIDs: Array.isArray(saved.completedOptionIDs)
          ? saved.completedOptionIDs.filter(
              (value): value is string => typeof value === "string",
            )
          : [],
      };
    }
  } catch {
    /* Storage can be unavailable or a preference may be from a newer version. */
  }
  return projectID.startsWith("local:") ? { startFieldID: "local-start", dueFieldID: "local-due", statusFieldID: "local-status", completedOptionIDs: ["local-done"] } : { completedOptionIDs: [] };
}
export function saveProjectScheduleSettings(
  accountID: string,
  projectID: string,
  settings: ProjectScheduleSettings,
): void {
  try {
    localStorage.setItem(key(accountID, projectID), JSON.stringify(settings));
  } catch {
    /* View choices still work in memory. */
  }
  if (typeof window !== "undefined")
    window.dispatchEvent(new Event("gitrochi-project-schedule-settings"));
}
