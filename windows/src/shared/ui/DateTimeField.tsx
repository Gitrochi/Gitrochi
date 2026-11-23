import { CalendarDays, ChevronLeft, ChevronRight, Clock } from "lucide-react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { language, t } from "@/shared/i18n";
import { dateTimePresets, minutesOfDay, monthGrid, startOfDay, timeSlots, withDay, withMinutes } from "@/shared/lib";
import "./date-time-field.css";

type Panel = "date" | "time" | null;

/**
 * A date and a time to pick: a date button opens a month, a time button a list of quarter hours, and a few ready-made
 * moments sit beside them. Days and times before `min` can't be picked. (macOS: Views/Shared/DateTimeField.swift)
 */
export function DateTimeField({ id, value, onChange, min, now }: {
  id?: string;
  value: number;
  onChange: (at: number) => void;
  /** The earliest moment to offer */
  min?: number;
  /** The clock for the ready-made moments */
  now: number;
}) {
  const [panel, setPanel] = useState<Panel>(null);
  const dateButton = useRef<HTMLButtonElement>(null), timeButton = useRef<HTMLButtonElement>(null);
  const date = new Intl.DateTimeFormat(language, { month: "short", day: "numeric", weekday: "short" }).format(value);
  const time = new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" }).format(value);
  const words: Record<string, string> = { hour: t("In 1 hour"), tonight: t("Tonight"), tomorrow: t("Tomorrow morning") };
  const full = (at: number) => new Intl.DateTimeFormat(language, { dateStyle: "medium", timeStyle: "short" }).format(at);
  return (
    <div className="dt-field" id={id} data-value={value}>
      <button ref={dateButton} type="button" className="dt-button" aria-haspopup="dialog" aria-expanded={panel === "date"} aria-label={t("Choose a date")} onClick={() => setPanel(panel === "date" ? null : "date")}>
        <CalendarDays size={13} /><span>{date}</span>
      </button>
      <button ref={timeButton} type="button" className="dt-button" aria-haspopup="listbox" aria-expanded={panel === "time"} aria-label={t("Choose a time")} onClick={() => setPanel(panel === "time" ? null : "time")}>
        <Clock size={13} /><span>{time}</span>
      </button>
      <span className="dt-presets">
        {dateTimePresets(now).map((p) => (
          <button key={p.id} type="button" className={`dt-preset ${p.at === value ? "on" : ""}`} data-preset={p.id} title={full(p.at)} onClick={() => onChange(p.at)}>{words[p.id]}</button>
        ))}
      </span>
      {panel === "date" && <Floating anchor={dateButton.current} close={() => setPanel(null)}><MonthPanel value={value} min={min} pick={(day) => { onChange(withDay(value, day)); setPanel(null); }} /></Floating>}
      {panel === "time" && <Floating anchor={timeButton.current} close={() => setPanel(null)}><TimePanel value={value} min={min} pick={(m) => { onChange(withMinutes(value, m)); setPanel(null); }} /></Floating>}
    </div>
  );
}

/** A panel under its button, above everything (the sheet's body scrolls and would cut it); a click outside or Escape closes it */
function Floating({ anchor, close, children }: { anchor: HTMLElement | null; close: () => void; children: React.ReactNode }) {
  const panel = useRef<HTMLDivElement>(null);
  const [at, setAt] = useState({ left: 0, top: 0 });
  useLayoutEffect(() => {
    const r = anchor?.getBoundingClientRect();
    if (r) setAt({ left: Math.min(r.left, window.innerWidth - 268), top: r.bottom + 4 });
  }, [anchor]);
  useEffect(() => {
    const down = (e: MouseEvent) => { if (!panel.current?.contains(e.target as Node) && !anchor?.contains(e.target as Node)) close(); };
    // Escape closes the panel before the sheet sees it
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); e.preventDefault(); close(); anchor?.focus(); } };
    window.addEventListener("mousedown", down, true);
    window.addEventListener("keydown", key, true);
    return () => { window.removeEventListener("mousedown", down, true); window.removeEventListener("keydown", key, true); };
  }, [anchor, close]);
  return createPortal(<div ref={panel} className="dt-panel" style={{ left: at.left, top: at.top }}>{children}</div>, document.body);
}

function MonthPanel({ value, min, pick }: { value: number; min?: number; pick: (day: number) => void }) {
  const [shown, setShown] = useState(() => { const d = new Date(value); return { year: d.getFullYear(), month: d.getMonth() }; });
  const today = startOfDay(Date.now()), chosen = startOfDay(value), first = min === undefined ? -Infinity : startOfDay(min);
  const step = (by: number) => setShown(({ year, month }) => { const d = new Date(year, month + by, 1); return { year: d.getFullYear(), month: d.getMonth() }; });
  const title = new Intl.DateTimeFormat(language, { year: "numeric", month: "long" }).format(new Date(shown.year, shown.month, 1));
  const days = monthGrid(shown.year, shown.month, 0);
  const weekday = new Intl.DateTimeFormat(language, { weekday: "narrow" });
  return (
    <div className="dt-month" role="dialog" aria-label={title}>
      <div className="dt-month-head">
        <button type="button" className="dt-nav" aria-label={t("Previous month")} onClick={() => step(-1)}><ChevronLeft size={14} /></button>
        <span className="dt-month-title">{title}</span>
        <button type="button" className="dt-nav" aria-label={t("Next month")} onClick={() => step(1)}><ChevronRight size={14} /></button>
      </div>
      <div className="dt-grid">
        {days.slice(0, 7).map((d) => <span key={`w${d.at}`} className="dt-weekday">{weekday.format(d.at)}</span>)}
        {days.map((d) => (
          <button key={d.at} type="button" disabled={d.at < first}
            className={`dt-day ${d.inMonth ? "" : "out"} ${d.at === chosen ? "on" : ""} ${d.at === today ? "today" : ""}`}
            aria-pressed={d.at === chosen} aria-label={new Intl.DateTimeFormat(language, { dateStyle: "full" }).format(d.at)} onClick={() => pick(d.at)}>{d.day}</button>
        ))}
      </div>
    </div>
  );
}

function TimePanel({ value, min, pick }: { value: number; min?: number; pick: (minutes: number) => void }) {
  const list = useRef<HTMLDivElement>(null);
  const chosen = minutesOfDay(value), format = new Intl.DateTimeFormat(language, { hour: "numeric", minute: "2-digit" });
  // the chosen time, or the nearest quarter, comes into view
  useLayoutEffect(() => { list.current?.querySelector<HTMLElement>(".on, [data-near]")?.scrollIntoView({ block: "center" }); }, []);
  const near = Math.round(chosen / 15) * 15;
  return (
    <div ref={list} className="dt-times" role="listbox" aria-label={t("Choose a time")}>
      {timeSlots(15).map((m) => {
        const at = withMinutes(value, m);
        return (
          <button key={m} type="button" role="option" aria-selected={m === chosen} data-near={m === near || undefined} disabled={min !== undefined && at < min}
            className={`dt-time ${m === chosen ? "on" : ""}`} onClick={() => pick(m)}>{format.format(at)}</button>
        );
      })}
    </div>
  );
}
