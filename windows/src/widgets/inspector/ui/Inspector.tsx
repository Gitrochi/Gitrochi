import { ArrowDownToLine, ArrowLeft, CircleCheck, CircleDot, CircleMinus, CirclePlus, Clock, ExternalLink, GitBranch, GitMerge, GitPullRequest, Hash, Layers, RefreshCw, Sparkles, TriangleAlert, Waypoints } from "lucide-react";
import { type ReactNode, useEffect, useMemo, useState } from "react";
import { ai } from "@/entities/ai";
import { avatars } from "@/entities/avatar";
import { CIStatusIcon, statusInfo } from "@/entities/ci";
import { type FileChange, markdownLinks, providerInfo, RefBadge, sameDiffSource, short, StatusBadge, statusCount, statusIsEmpty } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { laneColor, longDate, shortDate, useObserve } from "@/shared/lib";
import { Avatar, Button, Card, ChangeBar, Checkbox, Empty, IconButton, LineStatText, Markdown, type MenuItem, Spinner, tip } from "@/shared/ui";
import { ChangeList, FileViewToggle } from "./FileList";
import { GitchBar } from "./GitchBar";
import { WorktreeChanges } from "./WorktreeChanges";
import "./inspector.css";

/** 오른쪽 열: 작업 영역 또는 커밋 상세 */
export function Inspector({ store }: { store: RepoStore }) {
  useObserve(store);
  useObserve(ai);
  const sel = store.selection;
  if (!sel) return <Empty icon={<Waypoints size={30} strokeWidth={1.5} />} title={t("No commit selected")} detail={t("Select a commit in the graph.")} />;
  if (sel.kind === "wip") return <WorkingChanges store={store} />;
  if (sel.kind === "commit") return <CommitDetailView store={store} sha={sel.sha} />;
  if (sel.kind === "worktree") return <WorktreeChanges store={store} path={sel.path} />;
  return <PullRequestDetail store={store} number={sel.number} />;
}

// MARK: - 작업 영역

function WorkingChanges({ store }: { store: RepoStore }) {
  const st = store.status;
  const all = [...Object.values(store.stagedStats), ...Object.values(store.unstagedStats)];
  const added = all.reduce((a, s) => a + (s.added ?? 0), 0);
  const deleted = all.reduce((a, s) => a + (s.deleted ?? 0), 0);
  const isOpen = (c: FileChange) => sameDiffSource(store.diffSource, { kind: "working", change: c });
  const open = (c: FileChange) => store.openDiff({ kind: "working", change: c });
  const common = (c: FileChange): MenuItem[] => [
    ...(c.kind !== "untracked" && c.kind !== "added"
      ? ([
          { label: t("File history"), onClick: () => store.openFileHistory(c.path) },
          { label: t("Show blame"), disabled: c.kind === "deleted", onClick: () => store.openBlame(c.path) },
          "divider",
        ] as MenuItem[])
      : []),
    { label: t("Show in Explorer"), onClick: () => store.revealFile(c) },
    { label: t("Copy path"), onClick: () => store.copy(c.path) },
  ];
  return (
    <div className="col grow" style={{ height: "100%" }}>
      <div className="panel-head">
        <div className="col grow">
          <span style={{ fontSize: 15, fontWeight: 600 }}>{t("Uncommitted changes")}</span>
          <span className="row muted" style={{ fontSize: 11.5 }}>
            <GitBranch size={12} />
            <span className="ellipsis">{store.headBranch ?? t("Detached HEAD")}</span>
            {st.ahead > 0 && <span>↑{st.ahead}</span>}
            {st.behind > 0 && <span>↓{st.behind}</span>}
            {!statusIsEmpty(st) && (
              <>
                <span>·</span>
                <span style={{ whiteSpace: "nowrap" }}>{t("{0} files", statusCount(st))}</span>
                {added + deleted > 0 && <LineStatText added={added} deleted={deleted} />}
              </>
            )}
          </span>
        </div>
        <FileViewToggle />
      </div>
      {store.repoState !== "clean" && (
        <div className="banner">
          <span className="row" style={{ fontWeight: 600, color: "var(--orange)" }}>
            <TriangleAlert size={15} /> {store.repoStateTitle}
          </span>
          <span className="muted">{st.conflicted.length ? t("Fix the conflicted files in an editor, then click 'Mark as resolved'.") : t("All conflicts are resolved. Continue.")}</span>
          <div className="row">
            <Button onClick={() => store.abortOperation()}>{t("Abort…")}</Button>
            <span className="spacer" />
            <Button kind="primary" disabled={st.conflicted.length > 0} onClick={() => void store.continueOperation()}>
              {t("Continue")}</Button>
          </div>
        </div>
      )}
      <div className="panel-scroll">
        <FileSection title={t("Conflict")} color="var(--red)" count={st.conflicted.length} actionTitle={t("Mark all as resolved")} onAction={() => void store.stage(st.conflicted)}>
          <ChangeList
            folderMenu={(p) => folderMenu(store, p)}
            changes={st.conflicted}
            isSelected={isOpen}
            onOpen={open}
            action={{ icon: <CircleCheck size={14} />, tip: t("Mark as resolved (stage)"), run: (f) => void store.stage(f) }}
            menu={(c) => [{ label: t("Mark as resolved"), onClick: () => void store.stage([c]) }, "divider", ...common(c)]}
          />
        </FileSection>
        <FileSection title={t("Unstaged files")} color="var(--orange)" count={st.unstaged.length} actionTitle={t("Stage all")} onAction={() => void store.stageAll()}>
          <ChangeList
            folderMenu={(p) => folderMenu(store, p)}
            changes={st.unstaged}
            isSelected={isOpen}
            onOpen={open}
            stats={store.unstagedStats}
            action={{ icon: <CirclePlus size={14} />, tip: t("Stage"), run: (f) => void store.stage(f) }}
            menu={(c) => [
              { label: t("Stage"), onClick: () => void store.stage([c]) },
              { label: t("Discard changes…"), danger: true, onClick: () => store.confirmDiscard(c) },
              "divider",
              ...common(c),
            ]}
          />
        </FileSection>
        <FileSection title={t("Staged files")} color="var(--green)" count={st.staged.length} actionTitle={t("Unstage all")} onAction={() => void store.unstageAll()}>
          <ChangeList
            folderMenu={(p) => folderMenu(store, p)}
            changes={st.staged}
            isSelected={isOpen}
            onOpen={open}
            stats={store.stagedStats}
            action={{ icon: <CircleMinus size={14} />, tip: t("Unstage"), run: (f) => void store.unstage(f) }}
            menu={(c) => [{ label: t("Unstage"), onClick: () => void store.unstage([c]) }, "divider", ...common(c)]}
          />
        </FileSection>
        {statusIsEmpty(st) && (
          <Card>
            <span className="row" style={{ color: "var(--green)", fontWeight: 600 }}>
              <CircleCheck size={16} /> {" "}{t("Working directory is clean")}</span>
            <span className="muted">{t("Modified files appear here.")}</span>
          </Card>
        )}
      </div>
      <CommitComposer store={store} />
    </div>
  );
}

function FileSection({ title, color, count, actionTitle, onAction, children }: { title: string; color: string; count: number; actionTitle: string; onAction: () => void; children: ReactNode }) {
  if (!count) return null;
  return (
    <Card gap={4}>
      <div className="row" style={{ marginBottom: 4 }}>
        <span className="section-dot" style={{ background: color }} />
        <span style={{ fontWeight: 600 }}>{title}</span>
        <span className="muted">{count}</span>
        <span className="spacer" />
        <button className="link" onClick={onAction}>
          {actionTitle}
        </button>
      </div>
      {children}
    </Card>
  );
}

function CommitComposer({ store }: { store: RepoStore }) {
  useObserve(avatars);
  const n = store.status.staged.length;
  const title = store.amend ? t("Amend previous commit") : store.repoState === "merging" ? t("Merge commit") : n === 0 ? t("No staged files") : t("Commit {0} files  {1}", n, keyLabel("Ctrl+Enter"));
  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      void store.commit();
    }
  };
  return (
    <div className="composer">
      <div className="row" style={{ flexWrap: "wrap" }}>
        {store.me && (
          <span data-tip={`${store.me.name} <${store.me.email}>`}>
            <Avatar name={store.me.name} email={store.me.email} size={22} url={avatars.url(store.me.email, store.me.name)} />
          </span>
        )}
        <span style={{ fontWeight: 600 }}>{t("Commit")}</span>
        <span className="spacer" />
        <Button
          size="small"
          disabled={store.splittableChanges.length < 2 || !!store.aiWorking || store.status.conflicted.length > 0}
          onClick={() => void store.planSplit()}
          tip={tip(
            t("Split into commits"),
            t("{0} groups the changed files by topic and splits them into several commits. Review and edit the result, then commit. Rules are in Settings > Rules.", ai.shortFor("commit")),
          )}
        >
          <Layers size={13} /> {" "}{t("Split into commits")}</Button>
        <Button
          size="small"
          disabled={!n || !!store.aiWorking}
          onClick={() => void store.generateCommitMessage()}
          tip={tip(t("Write with {0}", ai.shortFor("commit")), t("The AI writes a commit message from the staged changes. Change the AI in Settings > AI and the rules in Settings > Rules."), "Ctrl+Alt+M")}
        >
          {store.aiWorking ? (
            <>
              <Spinner size={11} /> {" "}{t("Working")}</>
          ) : (
            <>
              <Sparkles size={13} /> {" "}{t("Write with {0}", ai.shortFor("commit"))}</>
          )}
        </Button>
      </div>
      <GitchBar store={store} />
      <div className="composer-box">
        <div className="row" style={{ paddingRight: 8 }}>
          <input value={store.summary} placeholder={t("Summary (required)")} onChange={(e) => store.setSummary(e.target.value)} onKeyDown={onKey} style={{ fontWeight: 500 }} spellCheck={false} />
          <span style={{ fontSize: 11.5, color: store.summary.length > 72 ? "var(--orange)" : "var(--text-3)", fontVariantNumeric: "tabular-nums" }}>{store.summary.length}</span>
        </div>
        <textarea value={store.message} placeholder={t("Description (optional)")} onChange={(e) => store.setMessage(e.target.value)} onKeyDown={onKey} spellCheck={false} />
      </div>
      {store.aiWorking && (
        <span className="hint row">
          <Spinner size={11} /> {store.aiWorking}
        </span>
      )}
      {store.aiNotice && <span className="hint">{store.aiNotice}</span>}
      <div className="row">
        <Checkbox checked={store.amend} disabled={!store.headHash} onChange={(v) => void store.setAmend(v)} label={t("Amend previous commit")} tip={t("Amend: combine into the last commit")} />
        <span className="spacer" />
        <Button kind="primary" size="large" disabled={!store.canCommit} onClick={() => void store.commit()} style={{ minWidth: 140 }}>
          {title}
        </Button>
      </div>
    </div>
  );
}

// MARK: - 커밋 상세

function CommitDetailView({ store, sha }: { store: RepoStore; sha: string }) {
  useObserve(avatars);
  const [expanded, setExpanded] = useState(false);
  const md = useMemo(() => markdownLinks(store.target), [store.target]);
  const d = store.detail;
  if (!d || d.sha !== sha)
    return (
      <div className="empty">
        <Spinner size={20} />
      </div>
    );
  const refs = store.refsByCommit.get(sha) ?? [];
  const idx = store.commitIndex.get(sha);
  const tint = idx !== undefined ? laneColor(store.entries[idx].row.color) : "var(--accent)";
  const long = d.body.length > 400 || d.body.split("\n").length > 9;
  const stats = Object.values(store.detailStats);
  const added = stats.reduce((a, s) => a + (s.added ?? 0), 0);
  const deleted = stats.reduce((a, s) => a + (s.deleted ?? 0), 0);
  const explanation = store.explanations[sha];
  return (
    <div className="col grow" style={{ height: "100%" }}>
      <div className="panel-head">
        <span className="muted" style={{ display: "inline-flex" }}>
          {d.parents.length > 1 ? <GitMerge size={15} /> : <CircleDot size={15} />}
        </span>
        <span style={{ fontWeight: 600 }}>{d.parents.length > 1 ? t("Merge commit") : t("Commit")}</span>
        <span className="mono muted">{sha.slice(0, 8)}</span>
        <span className="spacer" />
        <span className="muted">{shortDate(d.commitDate)}</span>
      </div>
      <div className="panel-scroll" key={sha}>
        <Card>
          {refs.length > 0 && (
            <div className="row" style={{ flexWrap: "wrap" }}>
              {refs.slice(0, 4).map((r) => (
                <RefBadge key={r.kind + r.name} label={r} color={tint} />
              ))}
              {refs.length > 4 && <span className="faint">+{refs.length - 4}</span>}
            </div>
          )}
          <div className="selectable" style={{ fontSize: 15, fontWeight: 600, wordBreak: "break-word" }}>
            {d.summary}
          </div>
          {d.body && (
            <>
              <Markdown
                text={d.body}
                {...md}
                className="muted"
                style={long && !expanded ? { maxHeight: 8 * 20, overflow: "hidden", maskImage: "linear-gradient(black 70%, transparent)" } : undefined}
              />
              {long && (
                <button className="link" style={{ alignSelf: "flex-start" }} onClick={() => setExpanded(!expanded)}>
                  {expanded ? t("Collapse") : t("Show all")}
                </button>
              )}
            </>
          )}
        </Card>
        <Card>
          <div className="row" style={{ gap: 10 }}>
            <Avatar name={d.author} email={d.email} size={34} url={avatars.url(d.email, d.author)} />
            <div className="col grow">
              <span style={{ fontWeight: 600 }} className="ellipsis">
                {d.author}
              </span>
              <span className="muted ellipsis" style={{ fontSize: 11.5 }}>
                {d.email}
              </span>
            </div>
            <div className="col" style={{ alignItems: "flex-end" }}>
              <span>{shortDate(d.date)}</span>
              <span className="muted" style={{ fontSize: 11 }}>
                {longDate(d.date)}
              </span>
            </div>
          </div>
          {(d.committer !== d.author || Math.abs(d.commitDate - d.date) > 60) && (
            <span className="row muted" style={{ fontSize: 11.5 }}>
              <Clock size={12} />
              {d.committer === d.author ? t("Commit: {0}", longDate(d.commitDate)) : t("Commit: {0} · {1}", d.committer, longDate(d.commitDate))}
            </span>
          )}
          <div style={{ height: 1, background: "var(--border)" }} />
          <div className="row" style={{ flexWrap: "wrap" }}>
            <button className="pill" data-tip={t("Copy full SHA")} onClick={() => store.copy(d.sha)}>
              <Hash size={10} /> {d.sha.slice(0, 8)}
            </button>
            {d.parents.length > 0 && <ArrowLeft size={11} className="faint" />}
            {d.parents.map((p) => (
              <button key={p} className="pill" data-tip={t("Go to parent commit")} onClick={() => store.reveal(p)}>
                {d.parents.length > 1 && <GitMerge size={10} />} {short(p)}
              </button>
            ))}
          </div>
        </Card>
        <Card>
          <div className="row">
            <span className="row" style={{ color: "var(--accent)", fontWeight: 600 }}>
              <Sparkles size={14} /> {" "}{t("{0} explanation", ai.shortFor("explain"))}</span>
            <span className="spacer" />
            {store.explaining.has(sha) ? (
              <span className="row muted" style={{ fontSize: 12 }}>
                <Spinner size={11} /> {" "}{t("Loading")}</span>
            ) : (
              <button className="link" onClick={() => void store.explainCommit(sha)}>
                {explanation ? t("Explain again") : t("Explain this commit")}
              </button>
            )}
          </div>
          {explanation && <div className="selectable markdown">{explanation}</div>}
        </Card>
        <Card gap={6}>
          <div className="row">
            <span style={{ fontWeight: 600 }}>{t("Changed files")}</span>
            <span className="muted">{store.detailFiles.length}</span>
            <span className="spacer" />
            <FileViewToggle />
          </div>
          {added + deleted > 0 && (
            <div className="row" style={{ marginBottom: 4 }}>
              <LineStatText added={added} deleted={deleted} />
              <ChangeBar added={added} deleted={deleted} />
            </div>
          )}
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
        </Card>
      </div>
    </div>
  );
}

// MARK: - PR 상세

function PullRequestDetail({ store, number }: { store: RepoStore; number: number }) {
  useObserve(store.ci);
  const [draft, setDraft] = useState("");
  useEffect(() => {
    setDraft("");
    void store.loadReview(number);
  }, [store, number]);
  const md = useMemo(() => markdownLinks(store.target), [store.target]);
  const pr = store.pullRequests.find((p) => p.number === number);
  const target = store.target;
  if (!pr || !target) return <Empty icon={<GitPullRequest size={30} />} title={t("{0} not in the list", target ? providerInfo[target.provider].requestShort : "PR")} detail={t("It was closed or hasn't been loaded yet.")} />;
  const r = store.review?.number === number ? store.review : null;
  const s = r?.state;
  const ci = pr.headSHA ? store.ci.bySha.get(pr.headSHA) : undefined;
  const text = draft.trim();
  const after = (ok: boolean) => ok && setDraft("");
  return (
    <div className="col grow" style={{ height: "100%" }}>
      <div className="panel-head">
        <GitPullRequest size={15} className="muted" />
        <span style={{ fontWeight: 600 }}>
          {providerInfo[target.provider].requestShort} #{pr.number}
        </span>
        {pr.isDraft && <span className="chip-warn">{t("Draft")}</span>}
        <span className="spacer" />
        {store.reviewLoading && <Spinner size={12} />}
        <IconButton small icon={<RefreshCw size={12} />} tip={t("Refresh conversation and approvals")} onClick={() => void store.loadReview(number)} />
      </div>
      <div className="panel-scroll" key={number}>
        <div className="selectable" style={{ fontSize: 16, fontWeight: 600 }}>
          {pr.title}
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "auto 1fr", gap: "6px 10px" }}>
          <span className="muted">{t("Author")}</span>
          <span>@{pr.author}</span>
          <span className="muted">{t("Branch")}</span>
          <span className="selectable">
            {pr.source} → {pr.target}
            {pr.fromFork ? t("  (fork)") : ""}
          </span>
          {pr.updated && (
            <>
              <span className="muted">{t("Update")}</span>
              <span>{longDate(pr.updated)}</span>
            </>
          )}
          {ci && (
            <>
              <span className="muted">CI</span>
              <span className="row" style={{ gap: 4 }}>
                <CIStatusIcon status={ci.status} size={12} />
                {statusInfo[ci.status].title} · #{ci.number}
                <button className="link" onClick={() => store.openUrl(ci.url)}>
                  {t("Open")}</button>
              </span>
            </>
          )}
        </div>
        <div className="row" style={{ flexWrap: "wrap" }}>
          <Button kind="primary" onClick={() => void store.checkoutPullRequest(pr)}>
            <ArrowDownToLine size={14} /> {" "}{t("Check out branch")}</Button>
          <Button onClick={() => store.openUrl(pr.url)}>
            <ExternalLink size={14} /> {" "}{t("Browser")}</Button>
          {pr.headSHA && store.commitIndex.has(pr.headSHA) && <Button onClick={() => store.reveal(pr.headSHA!)}>{t("Show in graph")}</Button>}
        </div>
        <div style={{ height: 1, background: "var(--border)" }} />
        {pr.body.trim() ? <Markdown text={pr.body} {...md} /> : <span className="muted">{t("No description")}</span>}
        {store.reviewError && (
          <span className="error-text" style={{ fontSize: 11.5, whiteSpace: "pre-wrap" }}>
            {store.reviewError}
          </span>
        )}
        {r && s && (
          <>
            <div className="col" style={{ gap: 4 }}>
              <span style={{ fontWeight: 600 }}>{t("Review")}</span>
              {!s.approvedBy.length && !s.changesRequestedBy.length && <span className="muted">{t("No one has approved yet.")}</span>}
              {s.approvedBy.length > 0 && <span style={{ color: "var(--green)" }}>{t("✓ Approved: {0}", s.approvedBy.map((x) => "@" + x).join(", "))}</span>}
              {s.changesRequestedBy.length > 0 && <span style={{ color: "var(--orange)" }}>{t("Changes requested: {0}", s.changesRequestedBy.map((x) => "@" + x).join(", "))}</span>}
              {s.approvalsLeft != null && s.approvalsLeft > 0 && <span className="muted" style={{ fontSize: 11.5 }}>{t("{0} more approvals needed.", s.approvalsLeft)}</span>}
            </div>
            <div className="col" style={{ gap: 2 }}>
              <span style={{ fontWeight: 600 }}>{t("Changed files {0}", r.files.length)}</span>
              {r.files.map((f) => {
                const open = store.diffSource?.kind === "review" && store.diffSource.number === number && store.diffSource.change.path === f.path;
                return (
                  <div
                    key={f.path}
                    className="side-row review-file"
                    style={{ background: open ? "var(--select)" : undefined }}
                    data-tip={f.patch ? t("Click to see the diff in the center") : t("Binary or too large — view it in the browser")}
                    onClick={() => store.openReviewFile(number, f)}
                  >
                    <StatusBadge kind={f.kind} />
                    <span className="ellipsis">{f.path.split("/").pop()}</span>
                    <span className="side-sub ellipsis grow">{f.path.split("/").slice(0, -1).join("/")}</span>
                    <LineStatText added={f.additions} deleted={f.deletions} />
                  </div>
                );
              })}
            </div>
            <div className="col" style={{ gap: 8 }}>
              <span style={{ fontWeight: 600 }}>{t("Conversation {0}", r.comments.filter((c) => c.kind !== "system").length)}</span>
              {r.comments.map((c) =>
                c.kind === "system" ? (
                  <span key={c.id} className="muted" style={{ fontSize: 11.5 }}>
                    @{c.author} {c.body}
                  </span>
                ) : (
                  <div key={c.id} className="review-comment">
                    <div className="row" style={{ gap: 6 }}>
                      <span style={{ fontWeight: 600 }}>@{c.author}</span>
                      {c.kind === "approved" && <span style={{ color: "var(--green)", fontSize: 11.5 }}>{t("✓ Approve")}</span>}
                      {c.kind === "changesRequested" && <span style={{ color: "var(--orange)", fontSize: 11.5 }}>{t("Request changes")}</span>}
                      <span className="spacer" />
                      {c.date != null && <span className="muted" style={{ fontSize: 11.5 }}>{shortDate(c.date)}</span>}
                    </div>
                    {c.path && (
                      <span className="mono muted" style={{ fontSize: 11 }}>
                        {c.path}
                        {c.line != null ? `:${c.line}` : ""}
                      </span>
                    )}
                    {c.body && <Markdown text={c.body} {...md} />}
                  </div>
                ),
              )}
            </div>
          </>
        )}
      </div>
      <div className="col" style={{ gap: 6, padding: 10, borderTop: "1px solid var(--border)" }}>
        <textarea
          className="textarea"
          style={{ height: 58 }}
          placeholder={t("Comment · review feedback")}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.ctrlKey || e.metaKey) && text) void store.postReviewComment(number, text).then(after);
          }}
        />
        <div className="row" style={{ gap: 6 }}>
          {store.reviewBusy && <Spinner size={12} />}
          <span className="spacer" />
          {target.provider === "github" && (
            <Button size="small" disabled={!text || store.reviewBusy} tip={t("Request changes with a comment (comment required)")} onClick={() => void store.requestChanges(number, text).then(after)}>
              {t("Request changes")}</Button>
          )}
          {target.provider === "gitlab" && s?.approvedByMe ? (
            <Button size="small" disabled={store.reviewBusy} onClick={() => void store.unapprovePullRequest(number)}>
              {t("Revoke approval")}</Button>
          ) : (
            <Button size="small" disabled={store.reviewBusy || !!s?.approvedByMe} tip={text ? t("Approve with a comment") : t("Approves this request")} onClick={() => void store.approvePullRequest(number, text).then(after)}>
              {t("✓ Approve")}</Button>
          )}
          <Button size="small" kind="primary" disabled={!text || store.reviewBusy} tip={keyLabel(t("Comment (Ctrl+Enter)"))} onClick={() => void store.postReviewComment(number, text).then(after)}>
            {t("Comment")}</Button>
        </div>
      </div>
    </div>
  );
}

/** 변경 목록 트리의 폴더 줄 우클릭 */
function folderMenu(store: RepoStore, path: string): MenuItem[] {
  return [
    { label: t("Show in Explorer"), onClick: () => void store.revealPath(path) },
    { label: t("Copy path"), onClick: () => store.copy(path) },
  ];
}
