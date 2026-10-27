import { useState } from "react";
import { AlertCircle, CalendarDays, Circle, ExternalLink } from "lucide-react";
import { localScheduleToday, parseScheduleDay } from "@/entities/hosting";
import type {
  HubDetail,
  HubProjectRow,
  ProjectScheduleFields,
} from "@/entities/hosting";
import { language, t } from "@/shared/i18n";
import { Button } from "@/shared/ui";
import { projectDateRange, projectRepository } from "../lib/project-workspace";

const day = 86_400_000;
const dateLabel = (value: number) =>
  new Date(value).toLocaleDateString(language, {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
export function ProjectRoadmap({
  detail,
  rows,
  selectedID,
  select,
  open,
  safe,
  scheduleFields,
  assignDate,
  locked = false,
}: {
  detail: HubDetail;
  rows: HubProjectRow[];
  selectedID: string | null;
  select: (row: HubProjectRow) => void;
  open: (url: string) => void;
  safe: (url: string) => boolean;
  scheduleFields?: ProjectScheduleFields;
  assignDate?: (row: HubProjectRow, date: string) => Promise<boolean>;
  locked?: boolean;
}) {
  const [dates, setDates] = useState<Record<string, string>>({}),
    [error, setError] = useState(""),
    [schedulingID, setSchedulingID] = useState<string | null>(null),
    [savingID, setSavingID] = useState<string | null>(null);
  const fields = detail.fields.filter((field) => field.kind === "date");
  const [startID, setStartID] = useState(
    fields.find((field) => /start|begin/i.test(field.name))?.id ??
      fields[0]?.id ??
      "",
  );
  const [endID, setEndID] = useState(
    fields.find(
      (field) =>
        /target|due|end|finish/i.test(field.name) && field.id !== startID,
    )?.id ??
      fields[1]?.id ??
      "",
  );
  const startField = scheduleFields
      ? scheduleFields.start
      : (fields.find((field) => field.id === startID) ?? fields[0]),
    endField = scheduleFields
      ? scheduleFields.due
      : fields.find(
          (field) => field.id === endID && field.id !== startField?.id,
        );
  const scheduled = rows
    .map((row) => ({ row, range: projectDateRange(row, startField, endField) }))
    .filter(
      (
        value,
      ): value is {
        row: HubProjectRow;
        range: NonNullable<ReturnType<typeof projectDateRange>>;
      } => value.range !== null,
    )
    .sort((a, b) => a.range.start - b.range.start);
  const scheduledIDs = new Set(scheduled.map((value) => value.row.id)),
    unscheduled = rows.filter((row) => !scheduledIDs.has(row.id));
  const first = scheduled.length
    ? Math.min(...scheduled.map((value) => value.range.start)) - day * 3
    : Date.UTC(2030, 0, 1);
  const last = scheduled.length
    ? Math.max(...scheduled.map((value) => value.range.end)) + day * 3
    : first + day * 30;
  const span = Math.max(day * 7, last - first),
    ticks = Array.from({ length: 5 }, (_, index) => first + (span * index) / 4);
  return (
    <section className="project-roadmap" aria-label={t("Project timeline")}>
      <div className="project-roadmap-controls">
        <span>
          <CalendarDays size={15} />
          <strong>{t("Timeline")}</strong>
        </span>
        {fields.length > 0 && !scheduleFields && (
          <div>
            <label>
              {t("Start date")}
              <select
                className="select"
                aria-label={t("Start date field")}
                value={startField?.id}
                onChange={(event) => setStartID(event.target.value)}
              >
                {fields.map((field) => (
                  <option key={field.id} value={field.id}>
                    {field.name}
                  </option>
                ))}
              </select>
            </label>
            <span>→</span>
            <label>
              {t("End date")}
              <select
                className="select"
                aria-label={t("End date field")}
                value={endField?.id ?? ""}
                onChange={(event) => setEndID(event.target.value)}
              >
                <option value="">{t("Single date")}</option>
                {fields
                  .filter((field) => field.id !== startField?.id)
                  .map((field) => (
                    <option key={field.id} value={field.id}>
                      {field.name}
                    </option>
                  ))}
              </select>
            </label>
          </div>
        )}
        <small>{t("{0} scheduled items", scheduled.length)}</small>
      </div>
      {!fields.length ? (
        <div className="project-canvas-empty">
          <CalendarDays size={28} />
          <strong>{t("Give your work a timeline")}</strong>
          <span>
            {t("Add a date field in GitHub, then schedule tasks here.")}
          </span>
          {safe(detail.item.url) && (
            <Button size="small" onClick={() => open(detail.item.url)}>
              <ExternalLink size={13} />
              {t("Open project settings")}
            </Button>
          )}
        </div>
      ) : (
        <>
          {scheduled.length > 0 ? (
            <div className="project-roadmap-scroll">
              <div className="project-roadmap-grid">
                <div className="project-roadmap-axis">
                  <span>{t("Task")}</span>
                  <div>
                    {ticks.map((value, index) => (
                      <time
                        key={index}
                        style={{ left: `${index * 25}%` }}
                        dateTime={new Date(value).toISOString().slice(0, 10)}
                      >
                        {dateLabel(value)}
                      </time>
                    ))}
                  </div>
                </div>
                {scheduled.map(({ row, range }) => (
                  <button
                    key={row.id}
                    className={`project-roadmap-row ${selectedID === row.id ? "selected" : ""}`}
                    onClick={() => select(row)}
                    title={`${row.title}\n${range.startText}${range.endText && range.endText !== range.startText ? ` → ${range.endText}` : ""}${range.reversed ? `\n${t("Start date is after end date.")}` : ""}`}
                  >
                    <span className="project-roadmap-title">
                      <Circle size={13} />
                      <span>
                        <strong>{row.title}</strong>
                        <small>
                          {projectRepository(row) ||
                            t(
                              detail.item.data.localProject === true
                                ? "Task"
                                : "Draft",
                            )}
                        </small>
                      </span>
                      {range.reversed && (
                        <AlertCircle
                          size={13}
                          aria-label={t("Start date is after end date.")}
                        />
                      )}
                    </span>
                    <span className="project-roadmap-track">
                      <span
                        className={`project-roadmap-bar ${range.start === range.end ? "milestone" : ""} ${range.reversed ? "reversed" : ""}`}
                        style={{
                          left: `${((range.start - first) / span) * 100}%`,
                          width: `${Math.max(1.5, ((range.end - range.start) / span) * 100)}%`,
                        }}
                      >
                        <span>
                          {dateLabel(range.start)}
                          {range.start !== range.end
                            ? ` – ${dateLabel(range.end)}`
                            : ""}
                        </span>
                      </span>
                    </span>
                  </button>
                ))}
              </div>
            </div>
          ) : (
            <div className="project-canvas-empty">
              <CalendarDays size={28} />
              <strong>{t("Your next milestones start here")}</strong>
              <span>
                {t("Choose a task and set its date in the details panel.")}
              </span>
            </div>
          )}
          {unscheduled.length > 0 && (
            <div className="project-roadmap-unscheduled">
              <div>
                <strong>{t("Unscheduled")}</strong>
                <span>{unscheduled.length}</span>
                <small>{t("Select a task to set its dates.")}</small>
              </div>
              {error && (
                <p role="alert" className="error-text">
                  {error}
                </p>
              )}
              {unscheduled.map((row) => (
                <div className="project-roadmap-unscheduled-row" key={row.id}>
                  <button onClick={() => select(row)}>
                    <Circle size={13} />
                    <strong>{row.title}</strong>
                  </button>
                  <div>
                    {schedulingID === row.id ? (
                      <>
                        <input className="input" type="date" aria-label={t("Date for {0}", row.title)}
                          value={dates[row.id] ?? ""} disabled={locked || !!savingID}
                          onChange={(event) => setDates((current) => ({ ...current, [row.id]: event.target.value }))} />
                        <Button size="small" disabled={locked || !!savingID || !parseScheduleDay(dates[row.id] ?? "")}
                          onClick={async () => {
                            if (!assignDate || savingID) return;
                            setError(""); setSavingID(row.id);
                            try {
                              if (await assignDate(row, dates[row.id])) setSchedulingID(null);
                            } catch (caught) {
                              setError(caught instanceof Error ? t(caught.message) : t("Could not schedule this task."));
                            } finally { setSavingID(null); }
                          }}>{t("Save date")}</Button>
                        <Button size="small" disabled={!!savingID} onClick={() => setSchedulingID(null)}>{t("Cancel")}</Button>
                      </>
                    ) : (
                      <Button size="small" disabled={locked || !assignDate || (!startField && !endField)} onClick={() => {
                        setSchedulingID(row.id);
                        setDates((current) => ({ ...current, [row.id]: current[row.id] ?? localScheduleToday() }));
                      }}><CalendarDays size={13} />{t("Schedule")}</Button>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </section>
  );
}
