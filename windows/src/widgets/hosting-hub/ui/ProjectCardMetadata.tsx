import { CalendarDays, Flag } from "lucide-react";
import { localScheduleToday, parseScheduleDay, type HubDetail, type HubProjectField, type HubProjectRow, type ProjectScheduleFields } from "@/entities/hosting";
import { language, t } from "@/shared/i18n";
import { projectFieldValue } from "../lib/project-workspace";

/** Color follows known status/priority names; unfamiliar options use a neutral accent. */
export function projectOptionTone(field: HubProjectField, option: string): string {
  const value = `${option} ${field.options.find((value) => value.id === option)?.name ?? ""}`.toLocaleLowerCase();
  if (/urgent|critical|highest|긴급|緊急/.test(value)) return "red";
  if (/done|complete|closed|완료|完了/.test(value)) return "green";
  if (/high|높음|高/.test(value)) return "orange";
  if (/progress|doing|진행|進行/.test(value)) return "accent";
  return "neutral";
}
export function ProjectCardMetadata({ row, detail, group, scheduleFields, completed = false }: {
  row: HubProjectRow;
  detail: HubDetail;
  group?: HubProjectField;
  scheduleFields?: ProjectScheduleFields;
  completed?: boolean;
}) {
  const local = detail.item.data.localProject === true,
    status = scheduleFields?.status ?? detail.fields.find((field) => field.id === "local-status" || /^status$/i.test(field.name)),
    priority = detail.fields.find((field) => field.id === "local-priority" || /^priority$/i.test(field.name)),
    dueField = scheduleFields?.due,
    due = dueField ? projectFieldValue(row, dueField) : "",
    dueTone = !completed && !/closed|merged/i.test(row.state ?? "") && parseScheduleDay(due) ? due < localScheduleToday() ? "overdue" : due === localScheduleToday() ? "today" : "" : "";
  const badge = (field: HubProjectField | undefined, isPriority = false) => {
    if (!field || field.id === group?.id) return null;
    const value = projectFieldValue(row, field), option = field.options.find((option) => option.id === value);
    return option ? <span className={`project-tag project-tone-${projectOptionTone(field, value)}`} key={field.id}>
      {isPriority ? <Flag size={10} /> : <i className="project-chip-dot" />}{local ? t(option.name) : option.name}
    </span> : null;
  };
  return (
    <span className="project-card-footer">
      <span className="project-labels">
        {badge(status)}{badge(priority, true)}
        {(row.labels ?? []).slice(0, 2).map((label) => <span className="project-tag" key={label}>{label}</span>)}
      </span>
      {parseScheduleDay(due) && <time className={`project-card-date ${dueTone}`} dateTime={due} title={due}>
        <CalendarDays size={11} />{due === localScheduleToday() ? t("Today") : new Date(`${due}T12:00:00Z`).toLocaleDateString(language, { month: "short", day: "numeric", timeZone: "UTC" })}
      </time>}
      {!!row.assignees?.length && <span className="project-avatar-group" aria-label={t("Assignees")}>
        {row.assignees.slice(0, 3).map((name) => <span className="project-avatar" key={name} title={`@${name}`}>{name.slice(0, 1).toUpperCase()}</span>)}
        {row.assignees.length > 3 && <span className="project-avatar" title={row.assignees.slice(3).join(", ")}>+{row.assignees.length - 3}</span>}
      </span>}
    </span>
  );
}
