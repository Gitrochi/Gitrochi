import type { HTMLAttributes, ReactNode } from "react";
import "./status-pill.css";

export type StatusTone = "waiting" | "failed" | "passed" | "info" | "neutral";

/** The shared 18 px status badge: an icon and label in the design's status tones. macOS: StatusPill. */
export function StatusPill({ tone, icon, children, className = "", ...props }: HTMLAttributes<HTMLSpanElement> & { tone: StatusTone; icon: ReactNode }) {
  return <span {...props} className={`status-pill status-tone ${className}`} data-tone={tone}><span className="status-pill-icon" aria-hidden>{icon}</span>{children}</span>;
}
