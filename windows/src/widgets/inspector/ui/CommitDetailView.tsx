import { CircleCheck, CircleDot, Copy, Ellipsis, Sparkles } from "@/shared/icons";
import { useMemo, useState } from "react";
import { ai } from "@/entities/ai";
import { avatars } from "@/entities/avatar";
import { type Commit, type CommitDetail, type CommitTrailers, markdownLinks, sameDiffSource, short } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { commitMenu } from "@/features/git-menus";
import { t } from "@/shared/i18n";
import { listWhen, longDate, useObserve } from "@/shared/lib";
import { Avatar, Button, FailureBlock, FileViewToggle, HostedListTextButton, IconButton, Markdown, type MenuItem, showMenuBelow, Spinner, StatusPill } from "@/shared/ui";
import { ChangeList } from "./FileList";
import "./commit-detail.css";

/**
 * The selected commit, as the redesign board's flat panel: a header as tall as the graph's (what it is, the short SHA, copy, ⋯),
 * then the message, its author, trailers, parents and actions, and the changed files. Nothing else: a commit's refs are on its
 * graph row. (macOS: CommitDetailView)
 */
export function CommitDetailView({ store, sha }: { store: RepoStore; sha: string }) {
  useObserve(avatars);
  useObserve(ai);
  const [expanded, setExpanded] = useState(false);
  const md = useMemo(() => markdownLinks(store.target), [store.target]);
  const d = store.detail;
  // a late answer for another commit is never shown under this one
  if (!d || d.sha !== sha)
    return (
      <div className="empty">
        <Spinner size={20} />
      </div>
    );
  const long = d.prose.length > 400 || d.prose.split("\n").length > 9;
  const explanation = store.explanations[sha], explaining = store.explaining.has(sha), failure = store.explainFailures[sha];
  const provider = ai.shortFor("explain");
  const merge = d.parents.length > 1;
  // the graph's own menu for this commit, so the two never drift apart
  const commit: Commit = { id: d.sha, parents: d.parents, author: d.author, email: d.email, date: d.date, subject: d.summary, body: d.body };
  const who = `${d.author} <${d.email}>`, dates = commitDates(d);
  return (
    <div className="col grow commit-detail status-tone" style={{ height: "100%" }}>
      <div className="commit-head">
        <h2>{merge ? t("Merge commit") : t("Commit")}</h2>
        <span className="mono commit-head-sha selectable">{short(sha)}</span>
        <IconButton className="commit-icon-button" icon={<Copy size={13} />} tip={t("Copy commit SHA")} aria-label={t("Copy commit SHA")} onClick={() => store.copy(d.sha)} />
        <span className="spacer" />
        <IconButton className="commit-icon-button" icon={<Ellipsis size={14} />} tip={t("More commit actions")} aria-label={t("More commit actions")} aria-haspopup="menu"
          onClick={(event) => showMenuBelow(event.currentTarget, commitMenu(store, commit))} />
      </div>
      <div className="panel-scroll" key={sha}>
        <div className="commit-main">
          <h3 className="commit-title selectable">{d.summary}</h3>
          <div className="commit-author">
            <Avatar name={d.author} email={d.email} size={20} url={avatars.url(d.email, d.author)} />
            <span className="commit-author-name ellipsis" title={who} data-tip={who}>{d.author}</span>
            <span className="commit-caption commit-author-when" title={dates} data-tip={dates}>{listWhen(d.date)}</span>
          </div>
          {d.prose && (
            <>
              <Markdown text={d.prose} {...md} className={`commit-body ${long && !expanded ? "folded" : ""}`} />
              {long && <HostedListTextButton className="commit-text-button" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>{expanded ? t("Collapse") : t("Show all")}</HostedListTextButton>}
            </>
          )}
          {(d.trailers.issues.length > 0 || d.trailers.coAuthors.length > 0) && <CommitTrailerRows store={store} trailers={d.trailers} />}
          {d.parents.length > 0 && (
            <div className="commit-parents">
              <span className="commit-caption">{merge ? t("Parents") : t("Parent")}</span>
              {d.parents.map((p) => (
                <button key={p} type="button" className="mono commit-parent" data-tip={t("Go to parent commit")} aria-label={`${t("Go to parent commit")} ${short(p)}`} onClick={() => store.reveal(p)}>
                  {short(p)}
                </button>
              ))}
            </div>
          )}
          <div className="commit-actions">
            {/* a running git command blocks both; the tip names it */}
            <Button disabled={!!store.busy} tip={store.busy ?? undefined} onClick={() => store.requestNewBranch(d.sha, short(d.sha))}>{t("New branch…")}</Button>
            <Button disabled={!!store.busy} tip={store.busy ?? undefined} onClick={() => store.openSheet({ kind: "tag", sha: d.sha })}>{t("Tag…")}</Button>
          </div>
          {explaining ? (
            <span className="commit-caption commit-explaining" role="status"><Spinner size={11} />{t("Loading")}</span>
          ) : failure ? (
            <FailureBlock className="commit-explain-failure" title={t("Couldn't explain this commit")} caption={failure} retry={() => void store.explainCommit(sha)} />
          ) : (
            <HostedListTextButton className="commit-text-button commit-explain" data-tip={provider} onClick={() => void store.explainCommit(sha)}>
              <Sparkles size={13} />
              {explanation ? t("Explain again") : t("Explain with AI…")}
            </HostedListTextButton>
          )}
          {/* the board draws no caption: the text sits under the button in the body's type, the provider on the button's hover */}
          {explanation && <div className="selectable markdown commit-body commit-explanation">{explanation}</div>}
        </div>
        <section className="commit-files" aria-label={t("Changed files")}>
          <div className="commit-files-head">
            <span className="commit-files-title">{t("Changed files")}</span>
            <span className="commit-count">{store.detailFiles.length}</span>
            <span className="spacer" />
            <FileViewToggle />
          </div>
          <div className="commit-file-list">
            <ChangeList
              folderMenu={(p) => folderMenu(store, p)}
              changes={store.detailFiles}
              stats={store.detailStats}
              isSelected={(c) => sameDiffSource(store.diffSource, { kind: "commit", sha, change: c, parent: d.parents[0] ?? null })}
              onOpen={(c) => store.openDiff({ kind: "commit", sha, change: c, parent: d.parents[0] ?? null })}
              menu={(c) => [
                { label: t("File history"), onClick: () => store.openFileHistory(c.path) },
                { label: t("Show blame at this commit"), disabled: c.kind === "deleted", onClick: () => store.openBlame(c.path, sha) },
                "divider",
                { label: t("Show in Explorer"), onClick: () => store.revealFile(c) },
                { label: t("Copy path"), onClick: () => store.copy(c.path) },
              ]}
            />
          </div>
        </section>
      </div>
    </div>
  );
}

/** The author date, and under it the committer and commit date when they are not the author's (a rebase, a cherry-pick) */
export function commitDates(d: Pick<CommitDetail, "author" | "date" | "committer" | "committerEmail" | "commitDate">): string {
  const authored = longDate(d.date), committed = longDate(d.commitDate);
  if (d.committer !== d.author) return `${authored}\n${t("Commit: {0} · {1}", `${d.committer} <${d.committerEmail}>`, committed)}`;
  return Math.abs(d.commitDate - d.date) > 60 ? `${authored}\n${t("Commit: {0}", committed)}` : authored;
}

const trailerVerb = (keyword: CommitTrailers["issues"][number]["keyword"]) => keyword === "fixes" ? t("Fixes") : keyword === "resolves" ? t("Resolves") : t("Closes");

/**
 * The board's Trailers group: the issues this commit closes, as links, then its co-authors. An issue's title shows only
 * once it was read (a connected account), and its state colours the icon. (macOS: CommitDetailView.trailers)
 */
function CommitTrailerRows({ store, trailers }: { store: RepoStore; trailers: CommitTrailers }) {
  return (
    <div className="commit-trailers" role="group" aria-label={t("Trailers")}>
      {trailers.issues.map((trailer) => {
        const item = store.trailerIssue(trailer.number), open = item ? ["open", "opened"].includes(item.state) : null;
        return (
          // without a hosting server there is no page to open
          <button key={trailer.number} type="button" className="commit-trailer commit-trailer-issue" disabled={!store.target} title={item?.title || undefined}
            onClick={() => store.openTrailerIssue(trailer.number)}>
            {open === false ? <CircleCheck size={14} aria-hidden="true" /> : <CircleDot size={14} aria-hidden="true" className={open ? "status-tone commit-trailer-open" : undefined} data-tone={open ? "passed" : undefined} />}
            <span className="commit-caption commit-trailer-verb">{trailerVerb(trailer.keyword)}</span>
            <span className="mono commit-trailer-number">#{trailer.number}</span>
            {item?.title && <span className="ellipsis commit-trailer-title">{item.title}</span>}
          </button>
        );
      })}
      {trailers.coAuthors.map((author) => (
        // the trailer as it was written
        <span key={author.email} className="commit-trailer commit-trailer-author" title={author.line} data-tip={author.line}>
          <Avatar name={author.name} email={author.email} size={16} url={avatars.url(author.email, author.name)} />
          <span className="ellipsis">{author.name}</span>
          <StatusPill tone="neutral">{t("Co-author")}</StatusPill>
        </span>
      ))}
    </div>
  );
}

/** A folder row of the tree: right-click */
export function folderMenu(store: RepoStore, path: string): MenuItem[] {
  return [
    { label: t("Show in Explorer"), onClick: () => void store.revealPath(path) },
    { label: t("Copy path"), onClick: () => store.copy(path) },
  ];
}
