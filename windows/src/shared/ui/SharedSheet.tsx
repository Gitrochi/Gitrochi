import { type ReactNode, useId, useLayoutEffect, useRef, useState } from "react";
import { t } from "@/shared/i18n";
import { DisabledReason } from "./NoticeBlock";
import { Button, Spinner, useDialogEscape } from "./ui";
import "./shared-sheet.css";

/** The sheet's one filled button */
export type SheetPrimary = {
  label: string;
  onClick: () => void;
  /** Why it can't be used now: the button is disabled and says so between Cancel and itself */
  disabledReason?: string | null;
  /** Disabled with nothing to say, while the sheet works */
  disabled?: boolean;
  busy?: boolean;
};

/**
 * One layout for every sheet (docs/design.md, App shell): it attaches under the toolbar, horizontally centred, and the
 * window behind it is not dimmed. Header: a 15 px semibold title and one 12 px context line in 20 px of padding over a
 * 1 px line. Footer: secondary actions on the left; on the right Cancel, the reason while the primary is disabled, then
 * the one filled primary. (macOS: Views/Shared/SharedSheet.swift)
 */
export function SharedSheet({ title, context, width = 560, onClose, secondary, cancelLabel, cancelDisabled = false, primary, className = "", children }: {
  title: string;
  /** What the sheet acts on, in one line */
  context?: string | null;
  width?: number;
  onClose: () => void;
  /** Plain actions at the footer's left */
  secondary?: ReactNode;
  /** "Cancel", or "Close" on a sheet with nothing to confirm */
  cancelLabel?: string;
  cancelDisabled?: boolean;
  primary?: SheetPrimary;
  className?: string;
  children?: ReactNode;
}) {
  const backdrop = useRef<HTMLDivElement>(null);
  const titleID = useId(), contextID = useId();
  const [top, setTop] = useState(0);
  useDialogEscape(backdrop, onClose);
  // the window's toolbar marks where sheets hang from; a window without one hangs them from its top edge
  useLayoutEffect(() => {
    const measure = () => setTop(Math.max(0, Math.round(document.querySelector("[data-sheet-anchor]")?.getBoundingClientRect().bottom ?? 0)));
    measure();
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, []);
  return (
    // `.modal-backdrop` keeps the keyboard handlers aware of an open dialog; here it only catches clicks
    <div ref={backdrop} className="modal-backdrop shared-sheet-backdrop" style={{ paddingTop: top }} onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`shared-sheet ${className}`} style={{ width, maxHeight: `calc(100vh - ${top + 24}px)` }} role="dialog" aria-modal="true" aria-labelledby={titleID} aria-describedby={context ? contextID : undefined}>
        <div className="shared-sheet-header">
          <div className="shared-sheet-heading">
            <h2 id={titleID} className="shared-sheet-title">{title}</h2>
            {context && <span id={contextID} className="shared-sheet-context" title={context}>{context}</span>}
          </div>
        </div>
        {children && <div className="shared-sheet-body">{children}</div>}
        <div className="shared-sheet-footer">
          {secondary}
          <span className="shared-sheet-gap" />
          {primary?.busy && <Spinner size={12} />}
          <Button className="shared-sheet-cancel" disabled={cancelDisabled} onClick={onClose}>{cancelLabel ?? t("Cancel")}</Button>
          {primary && (
            <DisabledReason reason={primary.disabledReason}>
              <Button kind="primary" className="shared-sheet-primary" disabled={primary.disabled || primary.busy} onClick={primary.onClick}>{primary.label}</Button>
            </DisabledReason>
          )}
        </div>
      </div>
    </div>
  );
}
