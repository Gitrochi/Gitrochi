import { useEffect, useRef } from "react";
import { ArrowRight, ShieldCheck, Trash2, X } from "lucide-react";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
/** A contextual review is reserved for destructive, batch and explicit scheduling operations. */
export function ProjectReviewDialog({
  title,
  body,
  project,
  owner,
  busy,
  disabled,
  error,
  confirm,
  cancel,
}: {
  title: string;
  body: string;
  project?: string;
  owner?: string;
  busy: boolean;
  disabled: boolean;
  error?: string | null;
  confirm: () => void;
  cancel: () => void;
}) {
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    panel.current?.focus();
    return () => previous?.focus();
  }, []);
  const actions: [string, string, boolean][] = [
    ["Delete local project?", "Delete project", true],
    ["Remove item from project?", "Remove from project", true],
    ["Remove selected items from project?", "Remove selected items", true],
    ["Delete this project field?", "Delete field", true],
    ["Delete this shared view?", "Delete view", true],
    ["Delete this item?", "Delete", true],
    ["Archive this project item?", "Archive", false],
    ["Restore this project item?", "Restore", false],
    ["Archive selected project items?", "Archive selected items", false],
    ["Restore selected project items?", "Restore selected items", false],
    ["Move this project item?", "Move", false],
    ["Reschedule this task?", "Reschedule", false],
    ["Convert this draft to an issue?", "Convert to issue", false],
  ];
  const action = actions.find(([key]) => title === t(key)),
    destructive = action?.[2] ?? false,
    lines = body.split("\n").filter(Boolean);
  return (
    <div className="project-review-backdrop">
      <div
        ref={panel}
        tabIndex={-1}
        className="hub-confirm project-review-sheet"
        role="alertdialog"
        aria-modal="true"
        aria-label={title}
        onKeyDown={(event) => {
          if (event.key === "Escape" && !busy) {
            event.preventDefault();
            cancel();
          }
          if (event.key === "Tab") {
            const buttons = [
                ...event.currentTarget.querySelectorAll<HTMLButtonElement>(
                  "button:not(:disabled)",
                ),
              ],
              first = buttons[0],
              last = buttons.at(-1);
            if (
              event.shiftKey &&
              (document.activeElement === first ||
                document.activeElement === panel.current)
            ) {
              event.preventDefault();
              last?.focus();
            } else if (!event.shiftKey && document.activeElement === last) {
              event.preventDefault();
              first?.focus();
            }
          }
        }}
      >
        <header>
          <div
            className={`project-review-symbol ${destructive ? "danger" : ""}`}
          >
            {destructive ? <Trash2 size={22} /> : <ShieldCheck size={22} />}
          </div>
          <Button
            aria-label={t("Close review")}
            tip={t("Close review")}
            disabled={busy}
            onClick={cancel}
          >
            <X size={16} />
          </Button>
        </header>
        <span className="project-review-eyebrow">
          Gitrochi · {t("Review change")}
        </span>
        <h2>{title}</h2>
        {project && <div className="project-review-project">
          <span>{owner}</span><strong>{project}</strong>
        </div>}
        <div className="project-review-content">
          {lines.map((line, index) => (
            <p className={destructive && index === lines.length - 1 && lines.length > 1 ? "project-review-warning" : undefined} key={index}>{line}</p>
          ))}
        </div>
        {error && (
          <div className="project-review-error" role="alert">
            {error}
          </div>
        )}
        <footer>
          <Button disabled={busy} onClick={cancel}>
            {t("Cancel")}
          </Button>
          <Button
            kind={destructive ? "danger" : "primary"}
            aria-label={t(action?.[1] ?? "Apply changes")}
            disabled={disabled || busy}
            onClick={confirm}
          >
            {busy ? <Spinner /> : <ArrowRight size={14} />}{" "}
            {t(action?.[1] ?? "Apply changes")}
          </Button>
        </footer>
      </div>
    </div>
  );
}
