import { Crosshair } from "lucide-react";
import { Check, Cloud, Copy, Ellipsis, GitBranch, Sparkles, Tag as TagIcon } from "@/shared/icons";
import { useMemo, useState } from "react";
import { ai } from "@/entities/ai";
import { avatars } from "@/entities/avatar";
import { type Commit, markdownLinks, type RefLabel, sameDiffSource, short } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { commitMenu } from "@/features/git-menus";
import { t } from "@/shared/i18n";
import { listWhen, longDate, useObserve } from "@/shared/lib";
import { Avatar, Button, ChangeBar, FailureBlock, FileViewToggle, HostedListTextButton, IconButton, LineStatText, Markdown, type MenuItem, showMenuBelow, Spinner } from "@/shared/ui";
import { ChangeList } from "./FileList";
import "./commit-detail.css";

/**
 * The selected commit, as the redesign board's flat panel: a 44 px header (what it is, the short SHA, copy, ⋯), then
 * the message, its author, parents and actions, and the changed files. (macOS: CommitDetailView)
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
  const refs = store.refsByCommit.get(sha) ?? [];
  const long = d.body.length > 400 || d.body.split("\n").length > 9;
  const stats = Object.values(store.detailStats);
  const added = stats.reduce((a, s) => a + (s.added ?? 0), 0);
  const deleted = stats.reduce((a, s) => a + (s.deleted ?? 0), 0);
  const explanation = store.explanations[sha], explaining = store.explaining.has(sha), failure = store.explainFailures[sha];
  const provider = ai.shortFor("explain");
  const merge = d.parents.length > 1;
  // the graph's own menu for this commit, so the two never drift apart
  const commit: Commit = { id: d.sha, parents: d.parents, author: d.author, email: d.email, date: d.date, subject: d.summary, body: d.body };
  const committed = d.committer !== d.author || Math.abs(d.commitDate - d.date) > 60;
  const who = `${d.author} <${d.email}>`;
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
          {refs.length > 0 && (
            <div className="commit-refs">
              {refs.slice(0, 4).map((r) => <CommitRefChip key={r.kind + r.name} label={r} />)}
              {refs.length > 4 && <span className="commit-caption" data-tip={refs.slice(4).map((r) => r.name).join("\n")}>+{refs.length - 4}</span>}
            </div>
          )}
          <h3 className="commit-title selectable">{d.summary}</h3>
          <div className="commit-author">
            <Avatar name={d.author} email={d.email} size={20} url={avatars.url(d.email, d.author)} />
            <span className="commit-author-name ellipsis" title={who} data-tip={who}>{d.author}</span>
            <span className="commit-caption commit-author-when" title={longDate(d.date)} data-tip={longDate(d.date)}>{listWhen(d.date)}</span>
          </div>
          {committed && (
            <span className="commit-caption commit-committer selectable" title={d.committer === d.author ? undefined : `${d.committer} <${d.committerEmail}>`}>
              {d.committer === d.author ? t("Commit: {0}", longDate(d.commitDate)) : t("Commit: {0} · {1}", d.committer, longDate(d.commitDate))}
            </span>
          )}
          {d.body && (
            <>
              <Markdown text={d.body} {...md} className={`commit-body ${long && !expanded ? "folded" : ""}`} />
              {long && <HostedListTextButton className="commit-text-button" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>{expanded ? t("Collapse") : t("Show all")}</HostedListTextButton>}
            </>
          )}
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
          {explanation && (
            <div className="commit-explanation">
              <span className="commit-caption commit-explanation-by"><Sparkles size={13} />{t("{0} explanation", provider)}</span>
              <div className="selectable markdown commit-body">{explanation}</div>
            </div>
          )}
          {explaining ? (
            <span className="commit-caption commit-explaining" role="status"><Spinner size={11} />{t("Loading")}</span>
          ) : failure ? (
            <FailureBlock className="commit-explain-failure" title={t("Couldn't explain this commit")} caption={failure} retry={() => void store.explainCommit(sha)} />
          ) : (
            <HostedListTextButton className="commit-text-button commit-explain" data-tip={provider} onClick={() => void store.explainCommit(sha)}>
              {!explanation && <Sparkles size={13} />}
              {explanation ? t("Explain again") : t("Explain with AI…")}
            </HostedListTextButton>
          )}
        </div>
        <section className="commit-files" aria-label={t("Changed files")}>
          <div className="commit-files-head">
            <span className="commit-files-title">{t("Changed files")}</span>
            <span className="commit-count">{store.detailFiles.length}</span>
            <span className="spacer" />
            <FileViewToggle />
          </div>
          {added + deleted > 0 && (
            <div className="commit-files-totals">
              <LineStatText added={added} deleted={deleted} />
              <ChangeBar added={added} deleted={deleted} />
            </div>
          )}
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

/** A branch or tag on this commit, in the board's neutral chip: the graph owns the lane colours. (macOS: CommitRefChip) */
function CommitRefChip({ label }: { label: RefLabel }) {
  const lead = label.kind === "tag" ? <TagIcon size={11} /> : label.kind === "head" ? <Crosshair size={11} /> : null;
  return (
    <span className="commit-ref" title={label.name} data-tip={label.name}>
      {label.isCurrent && label.kind === "local" && <Check size={10} strokeWidth={2.4} role="img" aria-label={t("Current branch")} />}
      {lead}
      <span className="ellipsis">{label.name}</span>
      {label.kind === "local" && <GitBranch size={11} />}
      {label.kind === "remote" && <Cloud size={11} />}
    </span>
  );
}

/** A folder row of the tree: right-click */
export function folderMenu(store: RepoStore, path: string): MenuItem[] {
  return [
    { label: t("Show in Explorer"), onClick: () => void store.revealPath(path) },
    { label: t("Copy path"), onClick: () => store.copy(path) },
  ];
}
