import { AlertCircle, CheckCircle2, Circle, GitBranch } from "lucide-react";
import {
  type HubProjectField,
  type ProjectScheduleEntry,
} from "@/entities/hosting";
import { language, t } from "@/shared/i18n";
import { projectFieldValue, projectRepository } from "../lib/project-workspace";

export const scheduleDateLabel = (
  value: string,
  options?: Intl.DateTimeFormatOptions,
) =>
  new Date(`${value}T12:00:00Z`).toLocaleDateString(language, {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
    ...options,
  });
export const scheduleStatusColor = (id: string) => {
  const colors = [
    "var(--accent)",
    "var(--green)",
    "var(--orange)",
    "var(--blue, var(--accent))",
    "var(--red)",
  ];
  return colors[
    [...id].reduce((sum, letter) => sum + letter.charCodeAt(0), 0) %
      colors.length
  ];
};
export function ProjectAgendaTask({
  entry,
  selected,
  select,
  complete,
  completionEnabled,
  status,
  today,
  localRepository,
}: {
  entry: ProjectScheduleEntry;
  selected: boolean;
  select: () => void;
  complete: () => void;
  completionEnabled: boolean;
  status?: HubProjectField;
  today: string;
  localRepository?: string;
}) {
  const value = status ? projectFieldValue(entry.row, status) : "",
    option = status?.options.find((option) => option.id === value),
    overdue = !entry.completed && !!entry.due && entry.due < today;
  return (
    <div
      className={`project-agenda-task ${selected ? "selected" : ""} ${entry.completed ? "completed" : ""}`}
    >
      <button
        className="project-complete-task"
        disabled={entry.completed || !completionEnabled}
        title={
          entry.completed
            ? t("Completed")
            : completionEnabled
              ? t("Complete task")
              : t("Choose a completion status in Schedule setup.")
        }
        aria-label={t("Complete task: {0}", entry.row.title)}
        onClick={complete}
      >
        {entry.completed ? <CheckCircle2 size={19} /> : <Circle size={19} />}
      </button>
      <button className="project-agenda-task-main" onClick={select}>
        <strong>{entry.row.title}</strong>
        <span>
          <span>
            {projectRepository(entry.row) || t(entry.row.id.startsWith("local-task:") ? "Task" : "Draft")}
            {entry.row.number ? ` #${entry.row.number}` : ""}
          </span>
          {option && (
            <span
              className="project-agenda-status"
              style={{ color: scheduleStatusColor(option.id) }}
            >
              {entry.row.id.startsWith("local-task:") ? t(option.name) : option.name}
            </span>
          )}
          {localRepository &&
            projectRepository(entry.row) === localRepository && (
              <GitBranch size={12} aria-label={t("Local repository")} />
            )}
        </span>
      </button>
      <div className="project-agenda-task-right">
        <span className={`project-agenda-date ${overdue ? "overdue" : ""}`}>
          {entry.invalidDate || entry.invalidRange ? (
            <AlertCircle size={12} aria-label={t("Check task dates")} />
          ) : null}
          {entry.due ? (
            <time dateTime={entry.due}>
              {entry.due === today ? t("Today") : scheduleDateLabel(entry.due)}
            </time>
          ) : (
            <span>{t("No due date")}</span>
          )}
        </span>
        <span className="project-avatar-group">
          {entry.row.assignees?.slice(0, 2).map((name) => (
            <span className="project-avatar" key={name} title={`@${name}`}>
              {name.slice(0, 1).toUpperCase()}
            </span>
          ))}
        </span>
      </div>
    </div>
  );
}
