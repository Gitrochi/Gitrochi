import { Circle, CircleCheck, CircleDot, Square, SquareCheck, TriangleAlert } from "lucide-react";
import { CircleAlert } from "@/shared/icons";
import {
  scheduleStage,
  type HubProjectField,
  type ProjectScheduleEntry,
  type ProjectScheduleSettings,
} from "@/entities/hosting";
import { language, t } from "@/shared/i18n";
import { Avatar, StatusPill } from "@/shared/ui";
import { projectFieldValue } from "../lib/project-workspace";

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
/**
 * The todo row of docs/design.md: checkbox, title, one line of meta, status pill, avatar. A done task shows a check and
 * a gray title. Every change is left to the parent. macOS: ProjectScheduleTaskRow.
 */
export function ProjectAgendaTask({
  entry,
  selected,
  select,
  complete,
  completionEnabled,
  status,
  settings,
  today,
}: {
  entry: ProjectScheduleEntry;
  selected: boolean;
  select: () => void;
  complete: () => void;
  completionEnabled: boolean;
  status?: HubProjectField;
  settings?: ProjectScheduleSettings;
  today: string;
}) {
  const value = status ? projectFieldValue(entry.row, status) : "",
    option = status?.options.find((option) => option.id === value),
    stage = scheduleStage(entry, status, settings),
    overdue = !entry.completed && !entry.invalidRange && !!entry.due && entry.due < today,
    invalid = entry.invalidDate || entry.invalidRange;
  // The project's own word for the status; a closed item without one is simply done.
  const name = option ? (entry.row.id.startsWith("local-task:") ? t(option.name) : option.name) : entry.completed ? t("Done") : "";
  const date = entry.date ? (entry.date === today ? t("Today") : scheduleDateLabel(entry.date)) : t("No due date");
  const assignee = entry.row.assignees?.[0];
  return (
    <div
      className={`project-todo ${selected ? "selected" : ""} ${entry.completed ? "done" : ""}`}
      role="listitem"
    >
      <button
        type="button"
        className="project-complete-task"
        role="checkbox"
        aria-checked={entry.completed}
        disabled={entry.completed || !completionEnabled}
        data-tip={
          entry.completed
            ? t("Done")
            : completionEnabled
              ? t("Mark as done")
              : t("Choose a completion status in Schedule setup.")
        }
        aria-label={t("Mark as done: {0}", entry.row.title)}
        onClick={complete}
      >
        {entry.completed ? <SquareCheck size={16} /> : <Square size={16} />}
      </button>
      <button type="button" className="project-todo-main" onClick={select}>
        <span className="project-todo-title">{entry.row.title}</span>
        {/* Overdue is said in words as well as in colour. */}
        <span className={`project-todo-meta ${overdue ? "overdue status-tone" : ""}`} data-tone={overdue ? "failed" : undefined}>
          {overdue ? <CircleAlert size={12} /> : invalid ? <TriangleAlert size={12} aria-label={t("Check task dates")} /> : null}
          {entry.date ? <time dateTime={entry.date}>{overdue ? `${t("Overdue")} · ${date}` : date}</time> : date}
        </span>
        <span className="project-todo-grow" />
        <span className="project-todo-pill">
          {name && (
            <StatusPill
              tone={stage === "done" ? "passed" : stage === "inProgress" ? "info" : "neutral"}
              icon={stage === "done" ? <CircleCheck /> : stage === "inProgress" ? <CircleDot /> : <Circle />}
            >
              {name}
            </StatusPill>
          )}
        </span>
        <span className="project-todo-avatar" role={assignee ? "img" : undefined} aria-label={assignee ? t("Assigned to @{0}", assignee) : undefined} data-tip={assignee ? `@${assignee}` : undefined}>
          {assignee && <Avatar name={assignee} email={assignee} size={20} />}
        </span>
      </button>
    </div>
  );
}
