import { useEffect, useState } from "react";
import { Check, ChevronDown, Copy, Folder, GitBranch } from "@/shared/icons";
import type { TerminalActivity } from "@/entities/terminal";
import { displayPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { showMenuBelow } from "@/shared/ui";

/** These actions prepare text for review; the terminal runs it only on Enter. (macOS: TerminalQuickCommand) */
export const quickCommands = () => [
  { title: t("Status"), command: "gitch ck" },
  { title: t("Preflight"), command: "gitch preflight" },
  { title: t("Pull request"), command: "gitch pr status" },
  { title: t("CI"), command: "gitch ci" },
];

/** The command rail; it folds into one "Commands" menu before it can crowd a narrow pane. (macOS: TerminalQuickActions) */
export function TerminalQuickActions({ folded, hint, enabled, insert }: { folded: boolean; hint: boolean; enabled: boolean; insert: (command: string) => void }) {
  const commands = quickCommands();
  return (
    <div className="term-rail" role="toolbar" aria-label={t("Commands")}>
      {folded ? (
        <button
          type="button"
          className="term-cmd commands"
          aria-haspopup="menu"
          disabled={!enabled}
          data-tip={`${t("Insert command")} · ${t("Insert, then Enter")}`}
          onClick={(e) => showMenuBelow(e.currentTarget, commands.map((c) => ({ label: c.title, shortcut: c.command, onClick: () => insert(c.command) })))}
        >
          <span className="g" aria-hidden="true">❯</span>
          {t("Commands")}
          <ChevronDown size={11} />
        </button>
      ) : (
        commands.map((c) => (
          <button type="button" key={c.command} className="term-cmd" disabled={!enabled} data-tip={c.command} onClick={() => insert(c.command)}>
            <span className="g" aria-hidden="true">❯</span>
            {c.title}
          </button>
        ))
      )}
      {hint && <span className="term-rail-hint ellipsis">{t("Insert, then Enter")}</span>}
    </div>
  );
}

/** Where the terminal is and what it does; a narrow pane drops the branch, then the shell. (macOS: TerminalStatusBar) */
export function TerminalStatusBar({
  directory,
  state,
  program,
  branch,
  unseen,
  nextUnseen,
}: {
  directory: string;
  state: TerminalActivity;
  /** null: dropped at this width */
  program: string | null;
  branch: string | null;
  unseen: number;
  nextUnseen: () => void;
}) {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timer);
  }, [copied]);
  useEffect(() => setCopied(false), [directory]);
  const path = displayPath(directory);
  return (
    <div className="term-status">
      <span className="term-status-path">
        <Folder size={12} />
        <span className="ellipsis" data-tip={path}>
          {path}
        </span>
        <button
          type="button"
          className="term-status-copy"
          aria-label={copied ? t("Folder path copied") : t("Copy current folder")}
          data-tip={copied ? t("Folder path copied") : t("Copy current folder")}
          onClick={() => void navigator.clipboard.writeText(directory).then(() => setCopied(true), () => {})}
        >
          {copied ? <Check size={12} /> : <Copy size={12} />}
        </button>
      </span>
      <span className="spacer" />
      {branch && (
        <span className="term-status-item term-status-branch ellipsis" data-tip={branch}>
          <GitBranch size={12} />
          <span className="ellipsis">{branch}</span>
        </span>
      )}
      {unseen > 0 && (
        <button type="button" className="term-status-item term-status-unseen" data-tip={t("Next terminal with new output")} onClick={nextUnseen}>
          <span className="term-mark dot" />
          {t("{0} new", unseen)}
        </button>
      )}
      {program && <span className="term-status-item term-status-shell">{program}</span>}
      <span className="term-status-item term-status-state" data-state={state}>
        {state === "running" ? t("Running") : state === "exited" ? t("Exited") : t("Idle")}
      </span>
    </div>
  );
}
