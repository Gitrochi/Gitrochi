import { CircleMinus, CirclePlus, Layers, TriangleAlert, Waypoints } from "lucide-react";
import { CircleCheck } from "@/shared/icons";
import { GitBranch, Sparkles } from "@/shared/icons";
import type { ReactNode } from "react";
import { ai } from "@/entities/ai";
import { avatars } from "@/entities/avatar";
import { type FileChange, sameDiffSource, statusCount, statusIsEmpty } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Avatar, Button, Card, Checkbox, FileViewToggle, HostedListEmpty, LineStatText, type MenuItem, SharedPane, SharedStack, Spinner, tip } from "@/shared/ui";
import { CommitDetailView, folderMenu } from "./CommitDetailView";
import { ChangeList } from "./FileList";
import { CommitImpactPanel } from "./CommitImpactPanel";
import { GitchBar } from "./GitchBar";
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
      <SharedStack className="panel-scroll" bodyClassName="working-file-sections">
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
        <CommitImpactPanel store={store} />
        {statusIsEmpty(st) && (
          <Card>
            <span className="row" style={{ color: "var(--green)", fontWeight: 600 }}>
              <CircleCheck size={16} /> {" "}{t("Working directory is clean")}</span>
            <span className="muted">{t("Modified files appear here.")}</span>
          </Card>
        )}
      </SharedStack>
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
      <SharedPane id={title}>{children}</SharedPane>
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
