import { type ReactNode, useEffect, useLayoutEffect, useRef, useState } from "react";
import { settings } from "@/shared/config";
import { ChevronDown, ChevronRight, Ellipsis, ExternalLink, RotateCw } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { firstError, firstLogLine, type LogLine, testNames, useObserve } from "@/shared/lib";
import { Button, type MenuItem, showMenuBelow, Spinner } from "./ui";
import "./status-pill.css";
import "./failed-check.css";

/**
 * One form for a failed check, its log and the heads of the groups checks are listed in (docs/design.md, Shared
 * components): pull request checks, Actions and Flows draw these. (macOS: Views/Shared/FailedCheckBlock.swift)
 */

/** The setting "Wrap long lines" turns on; without it only the lines that report a failure wrap */
const wrapSetting = "ciLogWrap";

/**
 * What failed and what to do about it: the status icon, the job's name, "Failed after 3m 12s" in the failed tone and
 * a 12 px caption naming the failed tests; then Jump to first error, Re-run job, open in browser and ⋯. The actions
 * drop below the words in a narrow column. The log goes in as its child.
 */
export function FailedCheckBlock({ icon, name, outcome, failed = true, tests = [], caption, busy = false, onJump, rerun, onOpen, menu, moreLabel, actions, form = "plain", className = "", children }: {
  icon: ReactNode;
  /** Left out where the column's own header names the job or step */
  name?: string;
  outcome: string;
  /** The outcome takes the failed tone; a job that did not fail keeps the header in neutral words */
  failed?: boolean;
  /** The failed tests by name: "1 test failed: SearchTests.testQuery" */
  tests?: string[];
  /** What the caption says when no test is named: the server's own summary */
  caption?: string | null;
  busy?: boolean;
  onJump?: () => void;
  rerun?: { label: string; disabled?: boolean; onClick: () => void };
  onOpen?: () => void;
  /** What ⋯ holds, read when it opens; `checkLogMenu` gives Wrap long lines and Copy log */
  menu?: () => MenuItem[];
  moreLabel?: string;
  /** A button only one page needs (Load log), placed before Re-run */
  actions?: ReactNode;
  /** A bordered card, a pane that fills its column under a ruled header, or the bare parts */
  form?: "card" | "pane" | "plain";
  className?: string;
  children?: ReactNode;
}) {
  const more = moreLabel ?? t("More job actions");
  const hasActions = !!(onJump || rerun || onOpen || menu || actions);
  return (
    <div className={`failed-check failed-check-${form} ${className}`}>
      <div className="failed-check-head">
        <div className="failed-check-line">
          <span className="failed-check-title">
            <span className="failed-check-icon">{icon}</span>
            {name && <span className="failed-check-name mono selectable">{name}</span>}
            {/* the failed tone on words that say it failed; the icon says it too */}
            <span className={`failed-check-outcome${failed ? " status-tone" : ""}`} data-tone="failed">{outcome}</span>
            {busy && <Spinner size={11} />}
          </span>
          {hasActions && (
            <span className="failed-check-actions">
              {onJump && <Button onClick={onJump}>{t("Jump to first error")}</Button>}
              {actions}
              {rerun && <Button disabled={rerun.disabled} onClick={rerun.onClick}><RotateCw size={14} />{rerun.label}</Button>}
              {onOpen && <Button className="failed-check-icon-button" tip={t("Open in browser")} aria-label={t("Open in browser")} onClick={onOpen}><ExternalLink size={13} /></Button>}
              {menu && <Button className="failed-check-icon-button" tip={more} aria-label={more} aria-haspopup="menu" onClick={(event) => showMenuBelow(event.currentTarget, menu())}><Ellipsis size={14} /></Button>}
            </span>
          )}
        </div>
        {tests.length > 0 ? (
          <span className="failed-check-caption">{tests.length === 1 ? t("1 test failed:") : t("{0} tests failed:", tests.length)} <span className="mono selectable">{testNames(tests)}</span></span>
        ) : caption ? <span className="failed-check-caption selectable">{caption}</span> : null}
      </div>
      {children}
    </div>
  );
}

/** What ⋯ on a log holds first: Wrap long lines and Copy log; a page adds its own after them */
export function checkLogMenu(copy: (() => void) | undefined, extra: MenuItem[] = []): MenuItem[] {
  const wrap = settings.get<boolean>(wrapSetting, false);
  return [
    { label: t("Wrap long lines"), checked: wrap, onClick: () => settings.set(wrapSetting, !wrap) },
    { label: t("Copy log"), disabled: !copy, onClick: copy },
    ...extra,
  ];
}

/**
 * Numbered log lines. The lines that report a failure wrap and stand out in the failed tone; the others keep their
 * length and scroll sideways, under a fade on the right edge while there is more that way. A log opens a few lines
 * before its first error; one without an error opens on its end and follows it.
 */
export function CheckLog({ label, lines, jump = 0, follow = false, truncated = false, className = "" }: {
  /** What a screen reader calls the region */
  label: string;
  lines: LogLine[];
  /** Counts presses of Jump to first error */
  jump?: number;
  /** The log is still being written: it follows its end whatever it holds */
  follow?: boolean;
  truncated?: boolean;
  className?: string;
}) {
  useObserve(settings);
  const wrap = settings.get<boolean>(wrapSetting, false);
  // the lines before the part the log opens on are shown on request
  const [all, setAll] = useState(false);
  const [edge, setEdge] = useState<{ more: boolean; inset: number }>({ more: false, inset: 0 });
  const scroll = useRef<HTMLDivElement>(null), following = useRef(true);
  const start = all ? 0 : firstLogLine(lines), target = firstError(lines);
  const measure = () => {
    const box = scroll.current;
    if (!box) return;
    // the fade stays clear of the vertical scroll bar
    const more = box.scrollWidth - box.clientWidth - box.scrollLeft > 1, inset = box.offsetWidth - box.clientWidth;
    setEdge((value) => (value.more === more && value.inset === inset ? value : { more, inset }));
  };
  useLayoutEffect(() => {
    const box = scroll.current;
    if (box && (follow || target == null) && following.current) box.scrollTop = box.scrollHeight;
    measure();
  }, [lines, wrap, all]);
  useEffect(() => {
    const box = scroll.current;
    if (!box || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(box);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    if (jump && target != null) scroll.current?.querySelector(`[data-line="${target}"]`)?.scrollIntoView({ block: "center" });
  }, [jump]);
  return (
    <div className={`check-log${wrap ? " wrap" : ""} ${className}`}>
      <div ref={scroll} className="check-log-scroll selectable mono" role="region" aria-label={label} tabIndex={0}
        onScroll={(event) => {
          const box = event.currentTarget;
          following.current = box.scrollTop + box.clientHeight >= box.scrollHeight - 8;
          measure();
        }}>
        {truncated && <p className="check-log-note">{t("Log preview is limited to 2 MB. Open the browser for the complete log.")}</p>}
        {start > 0 && <div className="check-log-earlier"><button type="button" onClick={() => setAll(true)}>{t("Show {0} earlier lines", start)}</button></div>}
        {!lines.length ? <p className="check-log-note">{t("No log output yet.")}</p> : lines.slice(start).map((line) => (
          <div key={line.n} className={`check-log-line${line.isError ? " error status-tone" : ""}`} data-tone={line.isError ? "failed" : undefined} data-line={line.n}>
            <span className="check-log-n">{line.n}</span>
            <span className="check-log-text">{line.text}</span>
          </div>
        ))}
      </div>
      {edge.more && <span className="check-log-fade" aria-hidden style={{ right: edge.inset }} />}
    </div>
  );
}

/**
 * The head of a group of checks: "Failed", "Passed 5". The count is left out where a tab already shows it. With
 * `onToggle` the head folds its group, and what it is given (the passed jobs' names) follows the title.
 */
export function CheckGroupHead({ title, count, open, onToggle, className = "", children }: {
  title: string;
  count?: number | null;
  open?: boolean;
  onToggle?: () => void;
  className?: string;
  children?: ReactNode;
}) {
  const words = <span className="check-group-title">{count == null ? title : `${title} ${count}`}</span>;
  if (!onToggle) return <span className={`check-group ${className}`}>{words}{children}</span>;
  return (
    <button type="button" className={`check-group ${className}`} aria-expanded={!!open} onClick={onToggle}>
      {open ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
      {words}
      {children}
    </button>
  );
}
