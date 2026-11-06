import { CircleAlert, Flag, UserRound } from "lucide-react";
import {
  scheduleProgress,
  scheduleWorkload,
  type HubProjectField,
  type HubProjectRow,
  type ProjectScheduleEntry,
  type ProjectScheduleSettings,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Avatar, StatusPill } from "@/shared/ui";
import { scheduleDateLabel } from "./ProjectAgendaTask";
/**
 * The cards beside the Schedule list, as the redesign's Projects board draws them: progress and the deadlines after
 * the week the list covers. The board draws no workload; it stays as a third card because nothing there replaces it.
 * macOS: ProjectDashboard's side cards.
 */
export function ProjectScheduleInsights({
  entries,
  later,
  today,
  status,
  settings,
  person,
  setPerson,
  select,
}: {
  entries: ProjectScheduleEntry[];
  /** Open tasks due after the week the list covers, soonest first */
  later: ProjectScheduleEntry[];
  today: string;
  status?: HubProjectField;
  settings: ProjectScheduleSettings;
  /** The assignee the workspace is filtered to, if any */
  person?: string;
  setPerson?: (value: string) => void;
  select: (row: HubProjectRow) => void;
}) {
  const progress = scheduleProgress(entries, status, settings),
    parts = [
      { id: "done", tone: "passed", label: t("Done"), count: progress.done },
      { id: "progress", tone: "info", label: t("In progress"), count: progress.inProgress },
      { id: "todo", tone: "neutral", label: t("To do"), count: progress.todo },
    ],
    workload = scheduleWorkload(entries, today)
      .filter((value) => value.active > 0)
      .sort((a, b) => b.active - a.active || a.assignee.localeCompare(b.assignee));
  return (
    <aside className="project-overview-side">
      <section className="project-side-card" aria-label={t("Progress")}>
        <span className="project-panel-title">{t("Progress")}</span>
        <strong className="project-progress-value">{t("{0}% done", progress.percent)}</strong>
        <div className="project-progress-bar" role="img" aria-label={parts.map((part) => `${part.label} ${part.count}`).join(", ")}>
          {parts.filter((part) => part.count > 0).map((part) => (
            <span key={part.id} className={`status-tone ${part.id}`} data-tone={part.tone} style={{ flex: `${part.count} 1 0` }} />
          ))}
        </div>
        <div className="project-progress-legend" aria-hidden>
          {parts.map((part) => (
            <span key={part.id}><i className={`status-tone ${part.id}`} data-tone={part.tone} />{part.label} {part.count}</span>
          ))}
        </div>
        {status && !settings.completedOptionIDs.length && (
          <span className="project-side-note">{t("Choose a completion status in Schedule setup.")}</span>
        )}
      </section>
      <section className="project-side-card" aria-label={t("Upcoming deadlines")}>
        <span className="project-panel-title">{t("Upcoming deadlines")}</span>
        {later.slice(0, 5).map((entry) => (
          <button type="button" className="project-deadline" key={entry.row.id} onClick={() => select(entry.row)}>
            <Flag size={13} />
            <span>{entry.row.title}</span>
            {entry.due && <time dateTime={entry.due}>{scheduleDateLabel(entry.due)}</time>}
          </button>
        ))}
        {!later.length && <span className="project-side-note">{t("Nothing is due after the next 7 days.")}</span>}
      </section>
      {workload.length > 0 && (
        <section className="project-side-card" aria-label={t("Team workload")}>
          <span className="project-panel-title">{t("Team workload")}</span>
          {workload.slice(0, 6).map((value) => {
            const content = <>
              {value.assignee ? <Avatar name={value.assignee} email={value.assignee} size={20} /> : <UserRound size={16} />}
              <span>{value.assignee ? `@${value.assignee}` : t("Unassigned")}</span>
              {value.overdue > 0 && <StatusPill tone="failed" icon={<CircleAlert />}>{t("Overdue")} {value.overdue}</StatusPill>}
              <b>{value.active}</b>
            </>;
            // A person narrows the whole workspace through its assignee filter; "nobody" is not a filter it has.
            return value.assignee && setPerson ? (
              <button type="button" className={`project-workload-row ${person?.toLowerCase() === value.assignee.toLowerCase() ? "on" : ""}`} key={value.assignee}
                aria-pressed={person?.toLowerCase() === value.assignee.toLowerCase()} onClick={() => setPerson(person?.toLowerCase() === value.assignee.toLowerCase() ? "" : value.assignee)}>
                {content}
              </button>
            ) : (
              <div className="project-workload-row" key={value.assignee || "__unassigned"}>{content}</div>
            );
          })}
        </section>
      )}
    </aside>
  );
}
