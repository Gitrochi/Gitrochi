import { CircleMinus, CirclePlus, TriangleAlert, Waypoints } from "lucide-react";
import { ChevronDown, ChevronRight, CircleCheck, Sparkles } from "@/shared/icons";
import { type ReactNode, useEffect, useState } from "react";
import { ai } from "@/entities/ai";
import { avatars } from "@/entities/avatar";
import { type FileChange, sameDiffSource, statusIsEmpty } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Avatar, Button, DisabledReason, FailureBlock, FileViewToggle, HostedListEmpty, HostedListTextButton, type MenuItem, SharedPane, SharedStack, Spinner, StatusPill, tip } from "@/shared/ui";
import { CommitDetailView, folderMenu } from "./CommitDetailView";
import { ChangeList } from "./FileList";
import { WorktreeChanges } from "./WorktreeChanges";
import { PullRequestDetailView } from "./PullRequestDetailView";
import "./inspector.css";

/** 오른쪽 열: 작업 영역 또는 커밋 상세 */
export function Inspector({ store }: { store: RepoStore }) {
  useObserve(store);
  useObserve(ai);
  const sel = store.selection;
  if (!sel) return <HostedListEmpty icon={<Waypoints size={24} strokeWidth={1.5} />} title={t("No commit selected")} caption={t("Select a commit in the graph.")} />;
  if (sel.kind === "wip") return <WorkingChanges store={store} />;
  if (sel.kind === "commit") return <CommitDetailView store={store} sha={sel.sha} />;
  if (sel.kind === "worktree") return <WorktreeChanges store={store} path={sel.path} />;
  return <PullRequestDetailView store={store} number={sel.number} />;
}

// MARK: - 작업 영역

/**
 * The uncommitted changes, as the redesign board draws them (aside.insp of RepositoryChanges): a header as tall as the
 * graph's, "Changed files" with the list/tree toggle, the Unstaged and Staged groups, and the commit composer below.
 * macOS: WorkingChangesView
 */
function WorkingChanges({ store }: { store: RepoStore }) {
  const st = store.status;
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
    <div className="col grow working-changes status-tone" style={{ height: "100%" }}>
      <div className="working-head">
        <h2>{t("Uncommitted changes")}</h2>
      </div>
      {store.repoState !== "clean" && (
        <div className="operation-banner status-tone" data-tone="waiting" role="status">
          <span className="operation-banner-icon" aria-hidden><TriangleAlert size={14} /></span>
          <div className="operation-banner-body">
            <span className="operation-banner-title">{store.repoStateTitle}</span>
            <span className="operation-banner-caption">{st.conflicted.length ? t("Fix the conflicted files in an editor, then click 'Mark as resolved'.") : t("All conflicts are resolved. Continue.")}</span>
            <div className="operation-banner-actions">
              <Button onClick={() => store.abortOperation()}>{t("Abort…")}</Button>
              <span className="spacer" />
              {/* the caption above is the reason while conflicts remain */}
              <Button kind="primary" disabled={st.conflicted.length > 0} onClick={() => void store.continueOperation()}>{t("Continue")}</Button>
            </div>
          </div>
        </div>
      )}
      {statusIsEmpty(st) ? (
        <HostedListEmpty icon={<CircleCheck size={24} strokeWidth={1.5} />} title={t("Working directory is clean")} caption={t("Modified files appear here.")} />
      ) : (
        <SharedStack className="panel-scroll working-scroll" bodyClassName="working-file-sections">
          <div className="working-files-head">
            <span className="working-files-title">{t("Changed files")}</span>
            <span className="spacer" />
            <FileViewToggle />
          </div>
          <FileSection store={store} title={t("Conflicted")} count={st.conflicted.length} actionTitle={t("Mark all as resolved")} onAction={() => void store.stage(st.conflicted)}>
            <ChangeList
              folderMenu={(p) => folderMenu(store, p)}
              changes={st.conflicted}
              isSelected={isOpen}
              onOpen={open}
              action={{ icon: <CircleCheck size={14} />, tip: t("Mark as resolved (stage)"), label: t("Mark as resolved"), run: (f) => void store.stage(f) }}
              menu={(c) => [{ label: t("Mark as resolved"), onClick: () => void store.stage([c]) }, "divider", ...common(c)]}
            />
          </FileSection>
          <FileSection store={store} title={t("Unstaged")} count={st.unstaged.length} actionTitle={t("Stage all")} onAction={() => void store.stageAll()}>
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
          <FileSection store={store} title={t("Staged")} count={st.staged.length} actionTitle={t("Unstage all")} onAction={() => void store.unstageAll()}>
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
        </SharedStack>
      )}
      <CommitComposer store={store} />
    </div>
  );
}

/**
 * A group of the working changes: its name in 12px semibold grey, a neutral count pill and one text button for the
 * whole group, then its files. macOS: FileSection
 */
function FileSection({ store, title, count, actionTitle, onAction, children }: { store: RepoStore; title: string; count: number; actionTitle: string; onAction: () => void; children: ReactNode }) {
  if (!count) return null;
  return (
    <section className="working-section" aria-label={title}>
      <div className="working-section-head">
        <span className="working-section-title">{title}</span>
        <StatusPill tone="neutral">{count}</StatusPill>
        <span className="spacer" />
        {/* a running git command blocks it; the tip names the command */}
        <HostedListTextButton disabled={store.busy != null} data-tip={store.busy ?? undefined} onClick={onAction}>{actionTitle}</HostedListTextButton>
      </div>
      <SharedPane id={title} className="working-section-files">{children}</SharedPane>
    </section>
  );
}

/**
 * The commit form under the working changes, as the redesign board draws it: who commits, one 28px Summary field with
 * its count out of 72, the description folded away until it is wanted, "AI message" as a text button and the one
 * filled Commit. macOS: CommitComposer
 */
function CommitComposer({ store }: { store: RepoStore }) {
  useObserve(avatars);
  const [expanded, setExpanded] = useState(!!store.message);
  // a description that arrives from elsewhere (the AI, a merge message) is shown
  useEffect(() => { if (store.message) setExpanded(true); }, [store.message]);
  const n = store.status.staged.length;
  // Amend previous commit is in the toolbar's ⋯; while it is on, the button says what it does
  const title = store.amend ? t("Amend commit") : store.repoState === "merging" ? t("Merge commit") : n === 0 ? t("Commit") : n === 1 ? t("Commit 1 file") : t("Commit {0} files", n);
  const reason = store.commitBlockedReason;
  const onKey = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      void store.commit();
    }
  };
  return (
    <div className="composer">
      {store.me && (
        <span className="composer-identity" data-tip={`${store.me.name} <${store.me.email}>`}>
          <Avatar name={store.me.name} email={store.me.email} size={20} url={avatars.url(store.me.email, store.me.name)} />
          <span className="composer-name">{store.me.name}</span>
          {/* the email gives way first: the name says who commits */}
          <span className="composer-email">· {store.me.email}</span>
        </span>
      )}
      <label className="composer-field">
        <input value={store.summary} aria-label={t("Commit summary")} placeholder={t("Summary")} onChange={(e) => store.setSummary(e.target.value)} onKeyDown={onKey} spellCheck={false} />
        {/* past 72 the count is in the waiting tone, never the accent */}
        <span className={`composer-count mono${store.summary.length > 72 ? " status-tone over" : ""}`} data-tone="waiting" aria-label={t("Summary character count")}>{store.summary.length}/72</span>
      </label>
      <button type="button" className="composer-disclosure" aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>
        {expanded ? <ChevronDown size={10} /> : <ChevronRight size={10} />}
        {t("Description (optional)")}
      </button>
      {expanded && <textarea className="composer-description" value={store.message} aria-label={t("Commit description")} onChange={(e) => store.setMessage(e.target.value)} onKeyDown={onKey} spellCheck={false} />}
      {store.aiWorking && (
        <span className="composer-note" role="status">
          <Spinner size={11} /> {store.aiWorking}
        </span>
      )}
      {store.commitMessageFailure && <FailureBlock title={t("Couldn't write the commit message")} caption={store.commitMessageFailure} retry={() => void store.generateCommitMessage()} />}
      {store.aiNotice && <span className="composer-note">{store.aiNotice}</span>}
      <div className="composer-actions">
        <HostedListTextButton
          className="composer-ai"
          disabled={!n || !!store.aiWorking || store.busy != null}
          onClick={() => void store.generateCommitMessage()}
          data-tip={tip(t("Write with {0}", ai.shortFor("commit")), t("The AI writes a commit message from the staged changes. Change the AI in Settings > AI and the rules in Settings > Rules."), "Ctrl+Alt+M")}
        >
          <Sparkles size={13} />
          {t("AI message")}
        </HostedListTextButton>
        <span className="spacer" />
        {/* the reason sits beside a disabled Commit, and wraps under the row when the panel is too narrow for that */}
        <DisabledReason reason={reason}>
          {/* while a merge or a rebase is in progress the banner's Continue is the filled one */}
          <Button kind={store.repoState === "clean" ? "primary" : "default"} className="composer-commit" onClick={() => void store.commit()}>
            {title}
            <span className="composer-key">{keyLabel("Ctrl+Enter")}</span>
          </Button>
        </DisabledReason>
      </div>
    </div>
  );
}
