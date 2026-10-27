import {
  ArrowUpRight,
  CalendarDays,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
} from "lucide-react";
import {
  portfolioTasks,
  scheduleAddDays,
  scheduleSummary,
  scheduleWeekDays,
  type HubItem,
  type ProjectPortfolioTask,
  type ProjectPortfolioState,
  type ProjectScheduleSettings,
} from "@/entities/hosting";
import { language, t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
export function WorkspacePlanningViews({
  mode,
  matchesTask,
  filtered,
  agenda,
  tasks,
  data,
  settings,
  today,
  anchor,
  setAnchor,
  focus,
  setFocus,
  opening,
  openProject,
  loadMore,
}: {
  mode: string;
  matchesTask: (task: ProjectPortfolioTask) => boolean;
  filtered: boolean;
  agenda: ProjectPortfolioTask[];
  tasks: ProjectPortfolioTask[];
  data: ProjectPortfolioState;
  settings: Record<string, ProjectScheduleSettings>;
  today: string;
  anchor: string;
  setAnchor: (value: string) => void;
  focus: string;
  setFocus: (value: string) => void;
  opening: boolean;
  openProject: (item: HubItem, rowID?: string) => Promise<void>;
  loadMore: (id: string) => void;
}) {
  const dateLabel = (day: string) =>
    new Intl.DateTimeFormat(language, {
      month: "short",
      day: "numeric",
      timeZone: "UTC",
    }).format(new Date(`${day}T00:00:00Z`));
  const taskRow = (task: ProjectPortfolioTask) => (
    <button
      className="planning-task"
      key={task.id}
      disabled={opening}
      onClick={() => void openProject(task.detail.item, task.entry.row.id)}
    >
      {task.entry.completed ? (
        <CheckCircle2 size={17} />
      ) : (
        <CalendarDays size={17} />
      )}
      <span>
        <strong>{task.entry.row.title}</strong>
        <small>{task.projectNames.join(" · ")}</small>
      </span>
      <time
        className={
          !task.entry.completed &&
          !task.entry.invalidRange &&
          task.entry.due &&
          task.entry.due < today
            ? "overdue"
            : ""
        }
      >
        {task.entry.invalidDate || task.entry.invalidRange
          ? t("Check task dates")
          : task.entry.date
            ? dateLabel(task.entry.date)
            : t("No date")}
      </time>
      <ArrowUpRight size={13} />
    </button>
  );

  return (
    <>
      {mode === "agenda" && (
        <div className="planning-agenda">
          <div className="planning-section-title">
            <h3>{t("Your next actions")}</h3>
            {focus !== "focus" && (
              <Button size="small" onClick={() => setFocus("focus")}>
                {t("Clear filter")}
              </Button>
            )}
          </div>
          {agenda.length ? (
            agenda.slice(0, 16).map(taskRow)
          ) : (
            <p className="planning-empty">
              {t(
                data.loading
                  ? "Loading project schedules…"
                  : "No tasks in this view. Choose projects or adjust your filters.",
              )}
            </p>
          )}
          {agenda.length > 16 && (
            <p className="muted">{t("Open a project to see its full plan.")}</p>
          )}
        </div>
      )}
      {mode === "week" && (
        <div>
          <div className="planning-section-title">
            <h3>{t("This week, in focus")}</h3>
            <div>
              <Button
                size="small"
                tip={t("Previous week")}
                onClick={() => setAnchor(scheduleAddDays(anchor, -7) ?? anchor)}
              >
                <ChevronLeft size={13} />
              </Button>
              <Button size="small" onClick={() => setAnchor(today)}>
                {t("Today")}
              </Button>
              <Button
                size="small"
                tip={t("Next week")}
                onClick={() => setAnchor(scheduleAddDays(anchor, 7) ?? anchor)}
              >
                <ChevronRight size={13} />
              </Button>
            </div>
          </div>
          <div className="planning-week">
            {scheduleWeekDays(anchor).map((day) => (
              <article className={day === today ? "today" : ""} key={day}>
                <h4>{dateLabel(day)}</h4>
                {tasks
                  .filter(
                    (task) =>
                      !task.entry.completed &&
                      !task.entry.invalidRange &&
                      task.entry.date === day,
                  )
                  .map(taskRow)}
                {!tasks.some(
                  (task) =>
                    !task.entry.completed &&
                    !task.entry.invalidRange &&
                    task.entry.date === day,
                ) && <p>{t("No scheduled work")}</p>}
              </article>
            ))}
          </div>
        </div>
      )}
      {mode === "projects" && (
        <div className="planning-projects">
          {data.details.map((detail) => {
            const subset = portfolioTasks([detail], settings)
                .filter(matchesTask)
                .map((task) => task.entry),
              progress = scheduleSummary(subset, today);
            if (filtered && !subset.length) return null;
            return (
              <article key={detail.item.id}>
                <h3>
                  <button
                    disabled={opening}
                    onClick={() => void openProject(detail.item)}
                  >
                    {detail.item.title}
                  </button>
                </h3>
                <progress
                  aria-label={t("Completed")}
                  max={Math.max(1, subset.length)}
                  value={progress.completed}
                />
                <small>
                  {t(
                    "{0} completed · {1} active",
                    progress.completed,
                    progress.active,
                  )}
                </small>
                {data.projectErrors[detail.item.id] && (
                  <small className="planning-warning">
                    {t("Refresh needed")}
                  </small>
                )}
                <div>
                  <Button
                    size="small"
                    disabled={opening}
                    onClick={() => void openProject(detail.item)}
                  >
                    {t("Open project schedule")}
                  </Button>
                  {detail.more && (
                    <Button
                      size="small"
                      disabled={data.loading}
                      onClick={() => loadMore(detail.item.id)}
                    >
                      {t("Load more tasks")}
                    </Button>
                  )}
                </div>
              </article>
            );
          })}
        </div>
      )}
    </>
  );
}
