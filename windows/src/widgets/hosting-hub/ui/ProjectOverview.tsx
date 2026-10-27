import { useState } from "react";
import {
  AlertCircle,
  ArrowRight,
  CalendarCheck2,
  CheckCircle2,
  Clock3,
  CalendarDays,
  Inbox,
  Plus,
} from "lucide-react";
import {
  scheduleAddDays,
  scheduleSummary,
  type HubProjectField,
  type HubProjectRow,
  type ProjectScheduleEntry,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { ProjectAgendaTask, scheduleDateLabel } from "./ProjectAgendaTask";
import { ProjectScheduleInsights } from "./ProjectScheduleInsights";

type Focus =
  | "active"
  | "overdue"
  | "today"
  | "upcoming"
  | "unscheduled"
  | "completed";
export function ProjectOverview({
  entries,
  today,
  selectedID,
  select,
  status,
  complete,
  completionEnabled,
  localRepository,
  calendar,
  add,
  manageFields,
  hasDueField,
  more,
  localProject = false,
  locked = false,
}: {
  entries: ProjectScheduleEntry[];
  today: string;
  selectedID: string | null;
  select: (row: HubProjectRow) => void;
  status?: HubProjectField;
  complete: (row: HubProjectRow) => void;
  completionEnabled: boolean;
  localRepository?: string;
  calendar: () => void;
  add: () => void;
  manageFields: () => void;
  hasDueField: boolean;
  more: boolean;
  localProject?: boolean;
  locked?: boolean;
}) {
  const [focus, setFocus] = useState<Focus>("active"),
    [person, setPerson] = useState<string | null>(null),
    [dayFocus, setDayFocus] = useState<string | null>(null),
    summary = scheduleSummary(entries, today),
    nextWeek = scheduleAddDays(today, 7) ?? today;
  const metrics = [
    {
      id: "overdue" as const,
      label: t("Overdue"),
      value: summary.overdue,
      icon: AlertCircle,
    },
    {
      id: "today" as const,
      label: t("Today"),
      value: summary.today,
      icon: CalendarCheck2,
    },
    {
      id: "upcoming" as const,
      label: t("Next 7 days"),
      value: summary.upcoming,
      icon: Clock3,
    },
    {
      id: "unscheduled" as const,
      label: t("Unscheduled"),
      value: summary.unscheduled,
      icon: Inbox,
    },
    {
      id: "completed" as const,
      label: t("Completed"),
      value: summary.completed,
      icon: CheckCircle2,
    },
  ];
  const agenda = entries
    .filter((entry) => {
      if (
        dayFocus &&
        (entry.completed || entry.invalidRange || entry.due !== dayFocus)
      )
        return false;
      if (
        person !== null &&
        (person
          ? !entry.row.assignees?.some(
              (name) => name.toLocaleLowerCase() === person.toLocaleLowerCase(),
            )
          : entry.row.assignees?.length)
      )
        return false;
      if (focus === "completed") return entry.completed;
      if (entry.completed) return false;
      if (focus === "overdue")
        return !entry.invalidRange && !!entry.due && entry.due < today;
      if (focus === "today") return !entry.invalidRange && entry.date === today;
      if (focus === "upcoming")
        return (
          !entry.invalidRange &&
          !!entry.date &&
          entry.date > today &&
          entry.date <= nextWeek
        );
      if (focus === "unscheduled") return !entry.date;
      return true;
    })
    .sort(
      (a, b) =>
        (a.due ?? "9999").localeCompare(b.due ?? "9999") ||
        a.row.title.localeCompare(b.row.title),
    );
  const completedPercent =
    summary.active + summary.completed
      ? Math.round(
          (summary.completed / (summary.active + summary.completed)) * 100,
        )
      : 0;
  return (
    <section className="project-overview" aria-label={t("Schedule overview")}>
      <div className="project-overview-heading">
        <div>
          <span className="project-eyebrow">{t("Plan with clarity")}</span>
          <h2>{t("Make the next move count")}</h2>
          <p>
            {t(
              "See what needs attention, balance the upcoming work, and move straight into code.",
            )}
          </p>
        </div>
        <div className="project-overview-actions">
        <Button size="small" kind="primary" disabled={locked} onClick={add}><Plus size={14} />{t("New task")}</Button>
        <Button size="small" onClick={calendar}>
          <CalendarDays size={14} />
          {t("Open calendar")}
          <ArrowRight size={13} />
        </Button>
        </div>
      </div>
      <div className="project-schedule-metrics">
        {metrics.map((metric) => (
          <button
            key={metric.id}
            className={`${focus === metric.id ? "active" : ""} ${metric.id}`}
            onClick={() => {
              setFocus(focus === metric.id ? "active" : metric.id);
              setPerson(null);
              setDayFocus(null);
            }}
            aria-pressed={focus === metric.id}
          >
            <span>
              <metric.icon size={15} />
              {metric.label}
            </span>
            <strong>{metric.value}</strong>
            <small>
              {metric.id === "upcoming"
                ? t("After today")
                : metric.id === "completed"
                  ? t("{0}% of loaded work", completedPercent)
                  : t("Loaded items")}
            </small>
          </button>
        ))}
      </div>
      {summary.invalid > 0 && (
        <div className="project-schedule-warning" role="status">
          <AlertCircle size={15} />
          {t(
            "{0} tasks have invalid dates or reversed ranges. Review their date fields before rescheduling.",
            summary.invalid,
          )}
        </div>
      )}
      {!hasDueField && (
        <div className="project-schedule-empty-field">
          <CalendarDays size={24} />
          <div>
            <strong>{t("Give every task a clear deadline")}</strong>
            <p>
              {t(
                "Choose a due date field in Schedule setup, or add a date field to this project.",
              )}
            </p>
          </div>
          <Button size="small" onClick={manageFields}>
            {t("Manage date fields")}
            <ArrowRight size={13} />
          </Button>
        </div>
      )}
      <div className="project-overview-grid">
        <div className="project-agenda project-schedule-panel">
          <header>
            <div>
              <h3>{t("Your agenda")}</h3>
              <p>
                {dayFocus
                  ? t("Due on {0}", scheduleDateLabel(dayFocus))
                  : person === null
                    ? t("Tasks ordered by due date")
                    : person
                      ? t("Assigned to @{0}", person)
                      : t("Unassigned work")}
              </p>
            </div>
            <span className="project-count">{agenda.length}</span>
          </header>
          <div
            className="project-agenda-tabs"
            role="group"
            aria-label={t("Agenda focus")}
          >
            <button
              className={focus === "active" ? "active" : ""}
              onClick={() => {
                setFocus("active");
                setDayFocus(null);
              }}
            >
              {t("All active")}
            </button>
            {metrics.map((metric) => (
              <button
                key={metric.id}
                className={focus === metric.id ? "active" : ""}
                onClick={() => {
                  setFocus(metric.id);
                  setDayFocus(null);
                }}
              >
                {metric.label}
              </button>
            ))}
            {(person !== null || dayFocus) && (
              <button
                onClick={() => {
                  setPerson(null);
                  setDayFocus(null);
                }}
              >
                {t("Clear focus filter")}
              </button>
            )}
          </div>
          <div className="project-agenda-list">
            {agenda.slice(0, 30).map((entry) => (
              <ProjectAgendaTask
                key={entry.row.id}
                entry={entry}
                today={today}
                status={status}
                selected={entry.row.id === selectedID}
                select={() => select(entry.row)}
                complete={() => complete(entry.row)}
                completionEnabled={completionEnabled}
                localRepository={localRepository}
              />
            ))}
            {!agenda.length && (
              <div className="project-canvas-empty">
                <CheckCircle2 size={28} />
                <strong>
                  {focus === "overdue"
                    ? t("Nothing overdue")
                    : t("No tasks in this focus")}
                </strong>
                <span>{t("Choose another focus or add your next task.")}</span>
                <Button size="small" kind="primary" disabled={locked} onClick={add}>
                  <Plus size={13} />{t("New task")}
                </Button>
              </div>
            )}
            {agenda.length > 30 && (
              <p className="project-schedule-footnote">
                {t(
                  "Showing the first {0} tasks. Use filters to narrow the agenda.",
                  30,
                )}
              </p>
            )}
          </div>
        </div>
        <ProjectScheduleInsights
          entries={entries}
          today={today}
          person={person}
          setPerson={(value) => {
            setPerson(value);
            setDayFocus(null);
            setFocus("active");
          }}
          selectDay={(value) => {
            setDayFocus(value);
            setFocus("active");
            setPerson(null);
          }}
          calendar={calendar}
        />
      </div>
      <p className="project-schedule-footnote">
        {more
          ? t("More items are available. Metrics cover loaded pages.")
          : t(
              localProject
                ? "Local tasks are saved on this device. Add dates and priorities to turn ideas into a plan."
                : "Schedule metrics use active, loaded project items and the selected date fields.",
            )}
      </p>
    </section>
  );
}
