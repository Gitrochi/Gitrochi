import { Crosshair } from "lucide-react";
import { Check, Cloud, GitBranch, Tag as TagIcon } from "@/shared/icons";
import { t } from "@/shared/i18n";
import type { LaneColors } from "@/shared/lib";
import type { ChangeKind, RefLabel } from "../model/types";
import "./badges.css";

/**
 * A changed file's status, as the boards draw it: one letter in its tone on that tone's fill, 18px square with a 4px
 * radius, 11px semibold, no border. Untracked is U, a conflict is C, a copy shares the rename's R and a type change
 * the modification's M. macOS: StatusBadge in Views/Shared/Theme.swift
 */
const kindInfo: Record<ChangeKind, { letter: string; tone: "passed" | "waiting" | "failed" | "info" | "neutral"; tip: string }> = {
  added: { letter: "A", tone: "passed", tip: t("Added") },
  modified: { letter: "M", tone: "waiting", tip: t("Modified") },
  deleted: { letter: "D", tone: "failed", tip: t("Deleted") },
  renamed: { letter: "R", tone: "info", tip: t("Renamed") },
  copied: { letter: "R", tone: "info", tip: t("Copied") },
  typeChanged: { letter: "M", tone: "waiting", tip: t("Type changed") },
  untracked: { letter: "U", tone: "neutral", tip: t("Untracked") },
  conflicted: { letter: "C", tone: "failed", tip: t("Conflicted") },
};

export function StatusBadge({ kind }: { kind: ChangeKind }) {
  const k = kindInfo[kind];
  return (
    <span className="status-badge status-tone" data-tone={k.tone} role="img" aria-label={k.tip} data-tip={k.tip}>
      {k.letter}
    </span>
  );
}

/** A ref as a badge: a branch is its lane colour on the lane's tint, filled when it is local. macOS: RefBadge in Views/Shared/Theme.swift */
export function RefBadge({ label, lane }: { label: RefLabel; lane: LaneColors }) {
  const outlined = label.kind === "remote";
  const fill = label.kind === "tag" ? "#8e8e93" : label.kind === "head" ? "var(--text)" : outlined ? lane.tint : lane.line;
  const Icon = label.kind === "head" ? Crosshair : label.kind === "local" ? GitBranch : label.kind === "remote" ? Cloud : TagIcon;
  return (
    <span
      className={`ref-badge ${label.isCurrent ? "current" : ""}`}
      data-tip={label.name}
      title={label.name}
      style={{
        color: outlined ? lane.line : label.kind === "head" ? "var(--surface)" : label.kind === "local" ? lane.onLine : "#fff",
        background: fill,
        boxShadow: outlined ? `inset 0 0 0 1px ${lane.line}` : undefined,
      }}
    >
      <Icon size={10} strokeWidth={2.5} />
      <span className="name">{label.name}</span>
      {label.isCurrent && label.kind === "local" && <Check size={9} strokeWidth={3.5} />}
    </span>
  );
}
