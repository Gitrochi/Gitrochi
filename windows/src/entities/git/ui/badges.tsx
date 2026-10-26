import { Check, Cloud, Crosshair, GitBranch, Tag as TagIcon } from "lucide-react";
import { t } from "@/shared/i18n";
import type { ChangeKind, RefLabel } from "../model/types";
import "./badges.css";

/** 파일 변경 종류 배지(A·M·D…) */
const kindInfo: Record<ChangeKind, { letter: string; color: string; tip: string }> = {
  added: { letter: "A", color: "rgb(46,158,92)", tip: t("Added") },
  modified: { letter: "M", color: "rgb(219,140,26)", tip: t("Modified") },
  deleted: { letter: "D", color: "rgb(219,66,77)", tip: t("Deleted") },
  renamed: { letter: "R", color: "rgb(41,133,245)", tip: t("Renamed") },
  copied: { letter: "C", color: "rgb(41,133,245)", tip: t("Copied") },
  typeChanged: { letter: "T", color: "rgb(219,140,26)", tip: t("Type changed") },
  untracked: { letter: "N", color: "rgb(46,158,92)", tip: t("New file (untracked)") },
  conflicted: { letter: "!", color: "rgb(191,26,51)", tip: t("Conflict") },
};

export function StatusBadge({ kind }: { kind: ChangeKind }) {
  const k = kindInfo[kind];
  return (
    <span className="status-badge" style={{ background: k.color }} data-tip={k.tip}>
      {k.letter}
    </span>
  );
}

export function RefBadge({ label, color }: { label: RefLabel; color: string }) {
  const outlined = label.kind === "remote";
  const tint = label.kind === "tag" ? "#8e8e93" : label.kind === "head" ? "var(--text)" : color;
  const Icon = label.kind === "head" ? Crosshair : label.kind === "local" ? GitBranch : label.kind === "remote" ? Cloud : TagIcon;
  return (
    <span
      className={`ref-badge ${label.isCurrent ? "current" : ""}`}
      data-tip={label.name}
      title={label.name}
      style={{
        color: outlined ? tint : label.kind === "head" ? "var(--surface)" : "#fff",
        background: outlined ? `color-mix(in srgb, ${tint} 12%, transparent)` : tint,
        boxShadow: outlined ? `inset 0 0 0 1px ${tint}` : undefined,
      }}
    >
      <Icon size={10} strokeWidth={2.5} />
      <span className="name">{label.name}</span>
      {label.isCurrent && label.kind === "local" && <Check size={9} strokeWidth={3.5} />}
    </span>
  );
}
