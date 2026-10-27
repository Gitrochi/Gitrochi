import { ArrowRight, CalendarDays, Users } from "lucide-react";
import {
  scheduleWeekDays,
  scheduleWorkload,
  type ProjectScheduleEntry,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { scheduleDateLabel } from "./ProjectAgendaTask";
export function ProjectScheduleInsights({
  entries,
  today,
  person,
  setPerson,
  selectDay,
  calendar,
}: {
  entries: ProjectScheduleEntry[];
  today: string;
  person: string | null;
  setPerson: (value: string | null) => void;
  selectDay: (day: string) => void;
  calendar: () => void;
}) {
  const week = scheduleWeekDays(today),
    workload = scheduleWorkload(entries, today),
    summaryActive = entries.filter((entry) => !entry.completed).length;
  const deadlineCounts = week.map(
      (day) =>
        entries.filter(
          (entry) =>
            !entry.completed && !entry.invalidRange && entry.due === day,
        ).length,
    ),
    maxDeadlines = Math.max(1, ...deadlineCounts),
    maxLoad = Math.max(1, ...workload.map((value) => value.active));
  return (
    <aside className="project-planning-sidebar">
      <div className="project-schedule-panel project-deadlines">
        <header>
          <div>
            <h3>{t("Deadlines this week")}</h3>
            <p>{t("Active tasks by due date")}</p>
          </div>
          <CalendarDays size={16} />
        </header>
        <div className="project-deadline-bars">
          {week.map((day, index) => (
            <button
              key={day}
              className={day === today ? "today" : ""}
              onClick={() => {
                selectDay(day);
              }}
              title={`${scheduleDateLabel(day)}: ${deadlineCounts[index]}`}
            >
              <b>{deadlineCounts[index]}</b>
              <span className="project-deadline-track">
                <i
                  style={{
                    height: `${deadlineCounts[index] ? Math.max(8, (deadlineCounts[index] / maxDeadlines) * 100) : 0}%`,
                  }}
                />
              </span>
              <time dateTime={day}>
                {scheduleDateLabel(day, {
                  weekday: "short",
                  month: undefined,
                  day: undefined,
                })}
              </time>
            </button>
          ))}
        </div>
        <button className="project-schedule-text-link" onClick={calendar}>
          {t("Plan on the calendar")}
          <ArrowRight size={12} />
        </button>
      </div>
      <div className="project-schedule-panel project-workload">
        <header>
          <div>
            <h3>{t("Team workload")}</h3>
            <p>{t("Active task counts by assignee")}</p>
          </div>
          <Users size={16} />
        </header>
        {workload
          .filter((value) => value.active > 0)
          .map((value) => (
            <button
              className={`project-workload-person ${person === value.assignee ? "selected" : ""}`}
              key={value.assignee || "__unassigned"}
              onClick={() => {
                setPerson(person === value.assignee ? null : value.assignee);
              }}
            >
              <span className="project-workload-name">
                <span className="project-avatar">
                  {value.assignee
                    ? value.assignee.slice(0, 1).toUpperCase()
                    : "?"}
                </span>
                <strong>
                  {value.assignee ? `@${value.assignee}` : t("Unassigned")}
                </strong>
                <b>{value.active}</b>
              </span>
              <span className="project-workload-track">
                <i
                  className="overdue"
                  style={{ width: `${(value.overdue / maxLoad) * 100}%` }}
                />
                <i
                  className="due"
                  style={{
                    width: `${((value.today + value.upcoming) / maxLoad) * 100}%`,
                  }}
                />
                <i
                  className="other"
                  style={{
                    width: `${(Math.max(0, value.active - value.overdue - value.today - value.upcoming) / maxLoad) * 100}%`,
                  }}
                />
              </span>
            </button>
          ))}
        {!summaryActive && (
          <p className="project-schedule-footnote">
            {t("No active work in loaded items.")}
          </p>
        )}
        <div className="project-workload-legend">
          <span>
            <i className="overdue" />
            {t("Overdue")}
          </span>
          <span>
            <i className="due" />
            {t("Due within 7 days")}
          </span>
          <span>
            <i className="other" />
            {t("Other active")}
          </span>
        </div>
        <p className="project-schedule-footnote">
          {t(
            "Shared tasks count once for each assignee. Counts do not estimate effort or capacity.",
          )}
        </p>
      </div>
    </aside>
  );
}
