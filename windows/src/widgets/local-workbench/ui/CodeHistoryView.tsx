import type { KeyboardEvent } from "react";
import { Clock } from "@/shared/icons";
import { avatars } from "@/entities/avatar";
import { short, type FileHistoryEntry } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { listWhen, useObserve } from "@/shared/lib";
import { Avatar, Empty, Spinner, StatusPill } from "@/shared/ui";
import { fileHistoryLimit } from "../lib/code-history";
import { CodeChangesView } from "./CodeChangesView";

interface Props {
  store: RepoStore;
  repo: string;
  /** null while the commits are being read */
  entries: FileHistoryEntry[] | null;
  /** The commits that are on no remote yet */
  local: ReadonlySet<string>;
  selected: string | null;
  select: (commit: string) => void;
  read: (args: string[], repo: string) => Promise<string>;
  wrap: boolean;
  setWrap: (value: boolean) => void;
  onLines: (count: number | null) => void;
}

/**
 * The History view of the Code page: the commits that changed the file in a 312px list column, and the chosen
 * commit's change beside it. (macOS: RepositoryCodeHistoryView)
 */
export function CodeHistoryView({ store, repo, entries, local, selected, select, read, wrap, setWrap, onLines }: Props) {
  useObserve(avatars);
  if (!entries) return <div className="code-loading" role="status"><Spinner/></div>;
  const shown = entries.slice(0, fileHistoryLimit), current = shown.find((entry) => entry.commit.id === selected) ?? shown[0];
  if (!current) return <Empty icon={<Clock size={24}/>} title={t("No history")} detail={t("This file hasn't been committed yet.")}/>;
  // the arrow keys move the selection, as in any list
  const move = (event: KeyboardEvent<HTMLElement>) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const next = shown[shown.indexOf(current) + (event.key === "ArrowDown" ? 1 : -1)];
    if (!next) return;
    event.preventDefault(); select(next.commit.id);
    event.currentTarget.querySelector<HTMLElement>(`[data-commit="${next.commit.id}"]`)?.focus();
  };
  return <div className="code-history">
    <section className="code-history-list" aria-label={t("Commits that changed this file")} onKeyDown={move}>
      {shown.map(({ commit }) => <button type="button" key={commit.id} data-commit={commit.id} className={`code-history-row ${commit.id === current.commit.id ? "on" : ""}`} aria-current={commit.id === current.commit.id ? "true" : undefined} onClick={() => select(commit.id)}>
        <span className="code-history-top"><span className="code-history-subject">{commit.subject}</span><span className="code-history-when">{listWhen(commit.date)}</span></span>
        <span className="code-history-meta">
          <Avatar name={commit.author} email={commit.email} size={16} url={avatars.url(commit.email, commit.author)}/>
          <span className="ellipsis">{commit.author}</span>
          <code>{short(commit.id)}</code>
          {/* a marker, not a status: neutral, and white on the selected row (docs/design.md, Selection) */}
          {local.has(commit.id) && <StatusPill tone="neutral" title={t("Commits not pushed to the remote")}>{t("local")}</StatusPill>}
        </span>
      </button>)}
    </section>
    <CodeChangesView store={store} repo={repo} path={current.path} commit={current.commit.id} read={read} wrap={wrap} setWrap={setWrap} onLines={onLines}/>
  </div>;
}
