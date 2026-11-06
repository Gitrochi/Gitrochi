import { useState } from "react";
import { CalendarPlus, CircleAlert, TriangleAlert } from "lucide-react";
import {
  scheduleGroup,
  scheduleOverview,
  type HubProjectField,
  type HubProjectRow,
  type ProjectScheduleEntry,
  type ProjectScheduleGroup,
  type ProjectScheduleSettings,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { ProjectAgendaTask } from "./ProjectAgendaTask";
import { ProjectScheduleInsights } from "./ProjectScheduleInsights";

/** Rows drawn before "Show N more": a project may hold hundreds of undated tasks */
const pageSize = 50;
const chips: { id: ProjectScheduleGroup; label: string }[] = [
  { id: "overdue", label: "Overdue" },
  { id: "today", label: "Today" },
  { id: "upcoming", label: "Next 7 days" },
  { id: "unscheduled", label: "Unscheduled" },
];
/**
 * The project overview, as the redesign's Projects board draws it: chips that count the open tasks, the Schedule list
 * they add up to, and progress and later deadlines beside it. Everything is derived from the loaded tasks, the
 * project's own fields and real dates. macOS: ProjectDashboard.
 */
export function ProjectOverview({
  entries,
  today,
  selectedID,
  select,
  status,
  settings,
  complete,
  completionEnabled,
  manageFields,
  hasDateField,
  person,
  setPerson,
}: {
  entries: ProjectScheduleEntry[];
  today: string;
  selectedID: string | null;
  select: (row: HubProjectRow) => void;
  status?: HubProjectField;
  settings: ProjectScheduleSettings;
  complete: (row: HubProjectRow) => void;
  completionEnabled: boolean;
  manageFields: () => void;
  hasDateField: boolean;
  person?: string;
  setPerson?: (value: string) => void;
}) {
  // A pressed chip's group, "invalid" for the tasks whose dates need fixing, or null for the whole list.
  const [focus, setFocus] = useState<ProjectScheduleGroup | "invalid" | null>(null),
    [showingDone, setShowingDone] = useState(false),
    [limit, setLimit] = useState(pageSize);
  const overview = scheduleOverview(entries, today),
    invalid = entries.filter((entry) => entry.invalidDate || entry.invalidRange);
  const listed =
    focus === "invalid"
      ? invalid
      : focus
        ? overview.rows.filter((entry) => scheduleGroup(entry, today) === focus)
        : [...overview.rows, ...(showingDone ? overview.done : [])];
  const choose = (value: typeof focus) => {
    setFocus(focus === value ? null : value);
    setLimit(pageSize);
  };
  return (
    <section className="project-overview" aria-label={t("Schedule overview")}>
      <div className="project-stats" role="group" aria-label={t("Task counts")}>
        {/* An empty Unscheduled chip would only be noise. */}
        {chips.filter((chip) => chip.id !== "unscheduled" || overview.counts.unscheduled > 0 || focus === "unscheduled").map((chip) => {
          const count = overview.counts[chip.id], alert = chip.id === "overdue" && count > 0;
          return (
            <button
              type="button"
              key={chip.id}
              className={`project-stat ${focus === chip.id ? "on" : ""} ${alert ? "alert status-tone" : ""} ${count ? "" : "zero"}`}
              data-tone={alert ? "failed" : undefined}
              aria-pressed={focus === chip.id}
              onClick={() => choose(chip.id)}
            >
              {alert && <CircleAlert size={12} />}
              <span className="project-stat-n">{count}</span>
              <span className="project-stat-l">{t(chip.label)}</span>
            </button>
          );
        })}
      </div>
      {!hasDateField && (
        <div className="project-strip" role="status">
          <CalendarPlus size={14} />
          <span>
            <strong>{t("Give every task a clear deadline")}</strong>
            <small>{t("Choose a due date field in Schedule setup, or add a date field to this project.")}</small>
          </span>
          <Button onClick={manageFields}>{t("Manage date fields")}</Button>
        </div>
      )}
      {invalid.length > 0 && (
        <div className="project-strip warning status-tone" data-tone="waiting" role="status">
          <TriangleAlert size={14} />
          <span>
            <strong>{t("{0} tasks have invalid dates or reversed ranges. Review their date fields before rescheduling.", invalid.length)}</strong>
          </span>
          <Button onClick={() => choose("invalid")}>{t(focus === "invalid" ? "View all tasks" : "Date issues")}</Button>
        </div>
      )}
      <div className="project-overview-columns">
        <section className="project-schedule-list" aria-label={t("Schedule")}>
          <div className="project-schedule-head"><span className="project-panel-title">{t("Schedule")}</span></div>
          <div role="list" aria-label={t("Schedule")}>
            {listed.slice(0, limit).map((entry) => (
              <ProjectAgendaTask
                key={entry.row.id}
                entry={entry}
                today={today}
                status={status}
                settings={settings}
                selected={entry.row.id === selectedID}
                select={() => select(entry.row)}
                complete={() => complete(entry.row)}
                completionEnabled={completionEnabled}
              />
            ))}
          </div>
          {!listed.length && <div className="project-schedule-foot project-schedule-empty">{t(entries.length ? "No open tasks in this view" : "No tasks yet")}</div>}
          {listed.length > limit && (
            <div className="project-schedule-foot">
              <button type="button" className="project-text-button" onClick={() => setLimit(listed.length)}>{t("Show {0} more", listed.length - limit)}</button>
            </div>
          )}
          {!focus && overview.done.length > 0 && (
            <div className="project-schedule-foot">
              <button type="button" className="project-text-button" aria-expanded={showingDone} onClick={() => setShowingDone(!showingDone)}>
                {showingDone ? t("Hide done tasks") : t("Show {0} more done tasks", overview.done.length)}
              </button>
            </div>
          )}
        </section>
        <ProjectScheduleInsights
          entries={entries}
          later={overview.later}
          today={today}
          status={status}
          settings={settings}
          person={person}
          setPerson={setPerson}
          select={select}
        />
      </div>
    </section>
  );
}
