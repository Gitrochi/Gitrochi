import { useState } from "react";
import {
  AlertCircle,
  CalendarDays,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  GripVertical,
  Inbox,
} from "lucide-react";
import {
  parseScheduleDay,
  scheduleAddDays,
  scheduleMonthDays,
  scheduleWeekDays,
  type HubProjectField,
  type HubProjectRow,
  type ProjectScheduleEntry,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { projectFieldValue } from "../lib/project-workspace";
import { scheduleDateLabel, scheduleStatusColor } from "./ProjectAgendaTask";

const dragType = "application/x-gitrochi-schedule-task";
export function ProjectCalendar({
  entries,
  today,
  status,
  selectedID,
  select,
  reschedule,
  locked,
  hasDateField,
  manageFields,
}: {
  entries: ProjectScheduleEntry[];
  today: string;
  status?: HubProjectField;
  selectedID: string | null;
  select: (row: HubProjectRow) => void;
  reschedule: (row: HubProjectRow, date: string) => void;
  locked: boolean;
  hasDateField: boolean;
  manageFields: () => void;
}) {
  const [mode, setMode] = useState<"month" | "week">("month"),
    [anchor, setAnchor] = useState(today),
    [dragged, setDragged] = useState<string | null>(null),
    [dropDay, setDropDay] = useState<string | null>(null),
    [taskID, setTaskID] = useState(""),
    [targetDate, setTargetDate] = useState(today),
    [error, setError] = useState<string | null>(null),
    [showCompleted, setShowCompleted] = useState(false);
  const visibleEntries = entries.filter(
    (entry) => showCompleted || !entry.completed,
  );
  const days =
      mode === "month" ? scheduleMonthDays(anchor) : scheduleWeekDays(anchor),
    unscheduled = visibleEntries.filter((entry) => !entry.date),
    task = entries.find((entry) => entry.row.id === taskID),
    canMove = !locked && hasDateField,
    title =
      mode === "month"
        ? scheduleDateLabel(anchor, {
            year: "numeric",
            month: "long",
            day: undefined,
          })
        : days.length
          ? `${scheduleDateLabel(days[0])} – ${scheduleDateLabel(days[6], { year: "numeric" })}`
          : "";
  const move = (row: HubProjectRow, date: string) => {
    if (!canMove) return;
    setError(null);
    try {
      reschedule(row, date);
    } catch (caught) {
      setError(
        caught instanceof Error
          ? t(caught.message)
          : t("Could not schedule this task."),
      );
    }
  };
  const navigate = (direction: number) => {
    if (mode === "week") {
      setAnchor(scheduleAddDays(anchor, direction * 7) ?? anchor);
      return;
    }
    const date = parseScheduleDay(`${anchor.slice(0, 7)}-01`);
    if (!date) return;
    date.setUTCMonth(date.getUTCMonth() + direction);
    const next = `${String(date.getUTCFullYear()).padStart(4, "0")}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-01`;
    if (parseScheduleDay(next)) setAnchor(next);
  };
  const event = (entry: ProjectScheduleEntry, compact = false) => {
    const option = status?.options.find(
        (option) => option.id === projectFieldValue(entry.row, status),
      ),
      invalid = entry.invalidDate || entry.invalidRange;
    return (
      <button
        key={entry.row.id}
        className={`project-calendar-event ${entry.completed ? "completed" : ""} ${selectedID === entry.row.id ? "selected" : ""} ${invalid ? "invalid" : ""}`}
        style={
          {
            "--schedule-event-color": option
              ? scheduleStatusColor(option.id)
              : "var(--accent)",
          } as React.CSSProperties
        }
        draggable={canMove && !invalid}
        onDragStart={(e) => {
          e.dataTransfer.setData(dragType, entry.row.id);
          e.dataTransfer.effectAllowed = "move";
          setDragged(entry.row.id);
        }}
        onDragEnd={() => {
          setDragged(null);
          setDropDay(null);
        }}
        onClick={() => select(entry.row)}
        title={`${entry.row.title}${entry.start && entry.due ? `\n${entry.start} → ${entry.due}` : ""}${option ? `\n${option.name}` : ""}`}
      >
        <span>
          {compact ? <GripVertical size={12} /> : <i />}
          <strong>{entry.row.title}</strong>
          {invalid && <AlertCircle size={11} />}
        </span>
        {(mode === "week" || compact) && (
          <small>
            {entry.row.assignees?.map((name) => `@${name}`).join(", ") ||
              t("Unassigned")}
          </small>
        )}
      </button>
    );
  };
  return (
    <section className="project-calendar" aria-label={t("Project calendar")}>
      <div className="project-calendar-toolbar">
        <div>
          <span className="project-eyebrow">{t("Make time for the work")}</span>
          <h2>{title}</h2>
        </div>
        <div className="project-calendar-navigation">
          <button
            className={`project-filter-toggle ${showCompleted ? "active" : ""}`}
            aria-pressed={showCompleted}
            onClick={() => setShowCompleted(!showCompleted)}
          >
            <CheckCircle2 size={13} />
            {t("Show completed")}
          </button>
          <Button size="small" onClick={() => setAnchor(today)}>
            {t("Today")}
          </Button>
          <Button
            size="small"
            aria-label={t("Previous period")}
            tip={t("Previous period")}
            onClick={() => navigate(-1)}
          >
            <ChevronLeft size={15} />
          </Button>
          <Button
            size="small"
            aria-label={t("Next period")}
            tip={t("Next period")}
            onClick={() => navigate(1)}
          >
            <ChevronRight size={15} />
          </Button>
          <div role="group" aria-label={t("Calendar period")}>
            <Button
              size="small"
              kind={mode === "month" ? "primary" : undefined}
              onClick={() => setMode("month")}
            >
              {t("Month")}
            </Button>
            <Button
              size="small"
              kind={mode === "week" ? "primary" : undefined}
              onClick={() => setMode("week")}
            >
              {t("Week")}
            </Button>
          </div>
        </div>
      </div>
      <p className="project-calendar-help">
        {t(
          "Tasks appear on their due date, or start date when no due date is set. Drag a task onto a day to review its new dates.",
        )}
      </p>
      {!hasDateField && (
        <div className="project-schedule-empty-field">
          <CalendarDays size={24} />
          <div>
            <strong>{t("Choose a date field to plan your work")}</strong>
            <p>
              {t(
                "Choose dates in Schedule setup, or add a date field to this project.",
              )}
            </p>
          </div>
          <Button size="small" onClick={manageFields}>
            {t("Manage date fields")}
          </Button>
        </div>
      )}
      {error && (
        <div className="project-schedule-warning" role="alert">
          <AlertCircle size={15} />
          {error}
        </div>
      )}
      <div className="project-calendar-layout">
        <div className="project-calendar-scroll">
          <div
            className={`project-calendar-grid ${mode}`}
            role="grid"
            aria-label={title}
          >
            {days.slice(0, 7).map((day) => (
              <div
                className="project-calendar-weekday"
                role="columnheader"
                key={day}
              >
                {scheduleDateLabel(day, {
                  weekday: "short",
                  month: undefined,
                  day: undefined,
                })}
              </div>
            ))}
            {days.map((day) => (
              <div
                role="gridcell"
                aria-label={scheduleDateLabel(day, {
                  weekday: "long",
                  year: "numeric",
                })}
                key={day}
                data-day={day}
                className={`project-calendar-day ${day === today ? "today" : ""} ${day.slice(0, 7) !== anchor.slice(0, 7) && mode === "month" ? "outside" : ""} ${dropDay === day ? "drop-target" : ""}`}
                onDragOver={(e) => {
                  if (
                    canMove &&
                    (dragged || e.dataTransfer.types.includes(dragType))
                  ) {
                    e.preventDefault();
                    e.dataTransfer.dropEffect = "move";
                    setDropDay(day);
                  }
                }}
                onDragLeave={(e) => {
                  if (!e.currentTarget.contains(e.relatedTarget as Node))
                    setDropDay(null);
                }}
                onDrop={(e) => {
                  e.preventDefault();
                  setDropDay(null);
                  setDragged(null);
                  const id = e.dataTransfer.getData(dragType),
                    entry = entries.find((entry) => entry.row.id === id);
                  if (entry) move(entry.row, day);
                }}
              >
                <time dateTime={day}>{Number(day.slice(8))}</time>
                <div>
                  {visibleEntries
                    .filter((entry) => entry.date === day)
                    .map((entry) => event(entry))}
                </div>
              </div>
            ))}
          </div>
        </div>
        <aside className="project-calendar-undated project-schedule-panel">
          <header>
            <div>
              <h3>
                <Inbox size={15} />
                {t("Unscheduled")}
              </h3>
              <p>{t("Drag onto a day to plan")}</p>
            </div>
            <span className="project-count">{unscheduled.length}</span>
          </header>
          <div>
            {unscheduled.map((entry) => event(entry, true))}
            {!unscheduled.length && (
              <p className="project-schedule-footnote">
                {t("Every loaded task has a date.")}
              </p>
            )}
          </div>
        </aside>
      </div>
      <details className="project-calendar-keyboard">
        <summary>
          <CalendarDays size={14} />
          {t("Schedule a task without dragging")}
        </summary>
        <div>
          <label>
            <span>{t("Task")}</span>
            <select
              className="select"
              aria-label={t("Task to schedule")}
              value={taskID}
              disabled={!canMove}
              onChange={(e) => setTaskID(e.target.value)}
            >
              <option value="">{t("Choose a task")}</option>
              {visibleEntries.map((entry) => (
                <option key={entry.row.id} value={entry.row.id}>
                  {entry.row.title}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span>{t("New date")}</span>
            <input
              className="input"
              type="date"
              aria-label={t("New task date")}
              value={targetDate}
              disabled={!canMove}
              onChange={(e) => setTargetDate(e.target.value)}
            />
          </label>
          <Button
            size="small"
            disabled={!canMove || !task || !parseScheduleDay(targetDate)}
            onClick={() => task && move(task.row, targetDate)}
          >
            {t("Review new dates")}
          </Button>
        </div>
      </details>
    </section>
  );
}
