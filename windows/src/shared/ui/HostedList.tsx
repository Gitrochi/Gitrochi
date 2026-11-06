import { CircleUserRound, CircleX } from "lucide-react";
import { ArrowUpDown, Search, X } from "@/shared/icons";
import type { ButtonHTMLAttributes, HTMLAttributes, MouseEvent, ReactNode } from "react";
import { t } from "@/shared/i18n";
import { listWhen } from "@/shared/lib";
import type { StatusTone } from "./StatusPill";
import { Button, type MenuItem, Segmented, showMenuBelow, Spinner } from "./ui";
import "./status-pill.css";
import "./hosted-list.css";

/**
 * The parts the Issues and Actions pages share, as their boards draw them: the row above the page (where it is and its
 * actions), the summary card, the 312 px list column with its search, segments and two-line rows, and the page states
 * of docs/design.md (empty, blocked, could not load). (macOS: Views/Shared/HostedList.swift)
 */

/** A hosted page; in a narrow window (under 680 px) it shows the list or the detail, and the summary becomes a strip */
export function HostedListPage({ className = "", children, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div {...props} className={`hosted-page ${className}`}>{children}</div>;
}

/** The row above the page: which repository on which server, and the page's actions on the right */
export function HostedListHeader({ host, path, children }: { host: string; path: string; children?: ReactNode }) {
  return (
    <div className="hosted-head">
      <span className="hosted-head-where ellipsis">{host} / {path}</span>
      <span className="spacer" />
      {children}
    </div>
  );
}

/**
 * The summary card every hosted page starts with: what it is about on the left, its picture in the middle and the one
 * next step on the right. In a narrow window it is a 44 px strip with the same words on one line.
 */
export function HostedListSummary({ label, lead, middle, trail, strip }: { label: string; lead: ReactNode; middle?: ReactNode; trail?: ReactNode; strip: ReactNode }) {
  return (
    <>
      <section className="hosted-summary" aria-label={label}>
        <div className="hosted-summary-lead">{lead}</div>
        <div className="hosted-summary-middle">{middle}</div>
        <div className="hosted-summary-trail">{trail}</div>
      </section>
      <section className="hosted-strip" aria-label={label}>{strip}</section>
    </>
  );
}

/** The list and the detail side by side; `detail` says whether there is one, which a narrow window shows instead of the list */
export function HostedListColumns({ detail, list, children }: { detail: boolean; list: ReactNode; children: ReactNode }) {
  return (
    <div className={`hosted-columns${detail ? " has-detail" : ""}`}>
      {list}
      <div className="hosted-detail">{children}</div>
    </div>
  );
}

/** The list column's first row: the search field and, beside it, the sort (and filter) menu */
export function HostedListSearch({ prompt, text, onText, onSearch, menuTitle, menu }: {
  prompt: string;
  text: string;
  onText: (text: string) => void;
  /** Enter searches; clearing searches again. A list that filters as you type passes nothing. */
  onSearch?: (text: string) => void;
  /** What the menu button says on hover and to screen readers, with the choices that are on */
  menuTitle: string;
  menu: () => MenuItem[];
}) {
  const clear = () => { onText(""); onSearch?.(""); };
  return (
    <div className="hosted-search">
      <label className="hosted-search-field">
        <Search size={13} />
        <input
          value={text}
          placeholder={prompt}
          aria-label={prompt}
          onChange={(event) => onText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") { event.preventDefault(); onSearch?.(text); }
            if (event.key === "Escape" && text) { event.preventDefault(); event.stopPropagation(); clear(); }
          }}
        />
        {text && <button type="button" className="hosted-search-clear" aria-label={t("Clear search")} data-tip={t("Clear search")} onClick={clear}><X size={12} /></button>}
      </label>
      <Button className="hosted-icon-button hosted-sort" aria-label={menuTitle} aria-haspopup="menu" tip={menuTitle} onClick={(event) => showMenuBelow(event.currentTarget, menu())}>
        <ArrowUpDown size={14} />
      </Button>
    </div>
  );
}

/** The list's filter. A segment carries a count only when it needs attention or is live; a count appears once per screen. */
export function HostedListSegments<T extends string>({ options, selection, onSelect }: {
  options: { value: T; title: string; count?: string | null }[];
  selection: T;
  onSelect: (value: T) => void;
}) {
  return (
    <div className="hosted-segments" role="group" aria-label={t("Filter")}>
      <Segmented stretch value={selection} onChange={onSelect} options={options.map((option) => ({ value: option.value, label: option.count ? `${option.title} ${option.count}` : option.title }))} />
    </div>
  );
}

/** A two-line list row: the selected one gets the tint and nothing else (no bar, no outline), any other the hover grey */
export function HostedListRow({ selected, title, when, children, className = "", ...props }: Omit<ButtonHTMLAttributes<HTMLButtonElement>, "title"> & {
  selected: boolean;
  title: string;
  /** When the item last changed, in the list's words */
  when?: string | null;
  /** The second line */
  children: ReactNode;
}) {
  return (
    <button type="button" {...props} className={`hosted-row${selected ? " selected" : ""} ${className}`} aria-current={selected || undefined}>
      <span className="hosted-row-top">
        <span className="hosted-row-title">{title}</span>
        {when && <span className="hosted-row-when">{when}</span>}
      </span>
      <span className="hosted-row-meta">{children}</span>
    </button>
  );
}

/** A marker in a row or a meta line (a linked request, a branch, a run that waits); it turns white on the selection tint */
export function HostedListChip({ icon, tone = "neutral", square = false, children, ...props }: HTMLAttributes<HTMLSpanElement> & { icon?: ReactNode; tone?: StatusTone; square?: boolean }) {
  return <span {...props} className={`hosted-chip status-tone${square ? " square" : ""}`} data-tone={tone}>{icon}<span className="ellipsis">{children}</span></span>;
}

/**
 * An empty or blocked page or column: a 24 px grey icon, one 15 px line, one caption and one action, which is filled
 * only when the state blocks the user (docs/design.md, Controls)
 */
export function HostedListEmpty({ icon, title, caption, action, failed = false }: {
  icon: ReactNode;
  title: string;
  caption?: string;
  action?: { label: string; onClick: () => void; filled?: boolean };
  /** A failed load shows the failed icon in its tone; the words say it too */
  failed?: boolean;
}) {
  return (
    <div className={`hosted-empty${failed ? " status-tone" : ""}`} data-tone={failed ? "failed" : undefined}>
      <span className="hosted-empty-icon" aria-hidden>{icon}</span>
      <span className="hosted-empty-title">{title}</span>
      {caption && <span className="hosted-empty-caption selectable">{caption}</span>}
      {action && <Button kind={action.filled ? "primary" : "default"} onClick={action.onClick}>{action.label}</Button>}
    </div>
  );
}

/** A hosted page without an account it can use: the one blocked state, with its filled action */
export function HostedAccountNeeded({ gitlab, host, path, onConnect }: { gitlab: boolean; host: string; path: string; onConnect: () => void }) {
  return (
    <HostedListEmpty
      icon={<CircleUserRound size={24} />}
      title={t("Connect a {0} account", gitlab ? "GitLab" : "GitHub")}
      caption={t("{0} is on {1}. Connect an account to see its pull requests, issues and runs.", path, host)}
      action={{ label: t("Connect account…"), filled: true, onClick: onConnect }}
    />
  );
}

/**
 * A list could not be refreshed and its last items stay: white with a hairline, the failed icon, what happened in the
 * failed tone, how old the data is, and Retry
 */
export function HostedListNotice({ title, caption, detail, retry }: { title: string; caption?: string; /** The server's own words, on hover */ detail?: string; retry: () => void }) {
  return (
    <div className="hosted-notice status-tone" data-tone="failed" role="alert" title={detail}>
      <CircleX size={14} />
      <span className="hosted-notice-text">
        <span className="hosted-notice-title">{title}</span>
        {caption && <span className="hosted-caption">{caption}</span>}
      </span>
      <Button onClick={retry}>{t("Retry")}</Button>
    </div>
  );
}

/** A list on its way: the words first, then three grey rows where the items will be */
export function HostedListLoading({ caption }: { caption: string }) {
  return (
    <div className="hosted-loading">
      <span className="hosted-caption hosted-loading-caption"><Spinner size={12} />{caption}</span>
      {[78, 64, 82].map((width) => (
        <span key={width} className="hosted-skeleton" aria-hidden><span style={{ width: `${width}%`, height: 12 }} /><span style={{ width: `${Math.round(width * 0.55)}%`, height: 10 }} /></span>
      ))}
    </div>
  );
}

/** A 12 px grey text button, at least 24 px tall; a destructive one is red and comes last (docs/design.md, Controls) */
export function HostedListTextButton({ destructive = false, className = "", ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { destructive?: boolean }) {
  return <button type="button" {...props} className={`hosted-text-button${destructive ? " destructive" : ""} ${className}`} />;
}

/** A 28 px button that is an icon alone; it explains itself on hover */
export function HostedListIconButton({ label, children, onClick, ...props }: Omit<ButtonHTMLAttributes<HTMLButtonElement>, "onClick"> & { label: string; onClick?: (event: MouseEvent<HTMLButtonElement>) => void }) {
  return <Button {...props} className="hosted-icon-button" aria-label={label} tip={label} onClick={onClick}>{children}</Button>;
}

/** "Showing data from 12m ago", for a list that could not be refreshed */
export const hostedListAge = (at: number | null) => (at == null ? undefined : t("Showing data from {0}", listWhen(at)));
