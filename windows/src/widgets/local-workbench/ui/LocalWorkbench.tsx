import { useEffect, useRef, useState, type ReactNode } from "react";
import { Cloud, GitBranch, Search, Tag, TriangleAlert } from "lucide-react";
import { validRevisionInput, fullObjectID, defaultRebaseBase, loadRebaseBases, loadRebasePreview, rebaseBaseMatches, statusIsEmpty, type RebaseBase, type RebasePreview } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { InteractiveRebaseSheet } from "@/features/interactive-rebase";
import { t } from "@/shared/i18n";
import { shortDate, useObserve } from "@/shared/lib";
import { describe, git } from "@/shared/platform";
import { Button, Checkbox, Segmented, Spinner } from "@/shared/ui";
import "./local-workbench.css";

type Props = { store: RepoStore };
type Mode = "move" | "cleanup";
const refs = (store: RepoStore) => [...store.localBranches.map((b) => b.name), ...store.remoteBranches.map((b) => b.name)];
const changed = (store: RepoStore) => new Set([...store.status.staged, ...store.status.unstaged, ...store.status.conflicted].map((file) => file.path)).size;

/** A numbered step: its number with a line down to the next one, and its title and content beside them */
function Step({ number, title, last = false, children }: { number: number; title: string; last?: boolean; children: ReactNode }) {
  return (
    <section className={`rebase-step${last ? " last" : ""}`} aria-label={title}>
      <div className="rebase-step-rail"><span className="rebase-num" aria-hidden>{number}</span>{!last && <span className="rebase-step-line" />}</div>
      <div className="rebase-step-body"><h3>{title}</h3>{children}</div>
    </section>
  );
}

/**
 * The Rebase page, as the redesign's Rebase board draws it: choose the new base in a list column, then review the
 * commits that replay and start. "Clean up history" chooses the oldest commit to include instead and builds the plan.
 * (macOS: RebaseWorkbenchPanel)
 */
export function RebaseWorkbenchPanel({ store, previewSource = loadRebasePreview, basesSource = loadRebaseBases }: Props & { previewSource?: typeof loadRebasePreview; basesSource?: typeof loadRebaseBases }) {
  useObserve(store);
  const repo = store.path;
  const [mode, setMode] = useState<Mode>("move");
  const [base, setBase] = useState(defaultRebaseBase(refs(store), store.headBranch, store.status.upstream));
  const [search, setSearch] = useState("");
  const [bases, setBases] = useState<RebaseBase[]>([]);
  // stash uncommitted changes for the rebase and restore them after
  const [stash, setStash] = useState(false);
  // clean up history: the oldest commit to include
  const [start, setStart] = useState("");
  const [planning, setPlanning] = useState(false), [error, setError] = useState<string | null>(null), [planKey, setPlanKey] = useState(0);
  const [preview, setPreview] = useState<RebasePreview | null>(null), [previewLoading, setPreviewLoading] = useState(false), [previewError, setPreviewError] = useState<string | null>(null);
  const request = useRef(0), previewRequest = useRef(0);
  useEffect(() => {
    setBase(defaultRebaseBase(refs(store), store.headBranch, store.status.upstream)); setStart(""); setError(null); setSearch("");
    return () => { ++request.current; };
  }, [repo]);
  useEffect(() => {
    if (!repo) { setBases([]); return; }
    let current = true;
    const head = store.headBranch;
    void basesSource(repo, head).catch(() =>
      // an older Git has no ahead-behind: the names without their counts
      [...store.localBranches.filter((b) => b.name !== head).map((b): RebaseBase => ({ name: b.name, kind: "branch", incoming: null })),
        ...store.remoteBranches.map((b): RebaseBase => ({ name: b.name, kind: "remote", incoming: null })),
        ...store.tags.map((b): RebaseBase => ({ name: b.name, kind: "tag", incoming: null }))]).then((value) => { if (current && store.path === repo) setBases(value); });
    return () => { current = false; };
  }, [repo, store.headHash, store.localBranches.length + store.remoteBranches.length + store.tags.length, basesSource]);
  useEffect(() => {
    const token = ++previewRequest.current, head = store.headHash; setPreview(null); setPreviewError(null); setPreviewLoading(false);
    if (!repo || store.repoState !== "clean") return;
    if (!head) { setPreviewError(t("Commit at least once to preview rebase.")); return; }
    if (!base) return;
    if (!validRevisionInput(base)) { setPreviewError(t("Choose a valid base branch to preview its commits.")); return; }
    setPreviewLoading(true);
    const timer = setTimeout(() => void previewSource(repo, base, head).then((value) => {
      if (token === previewRequest.current && store.path === repo && store.headHash === head) { setPreview(value); setStart((current) => current || value.commits.at(-1)?.id || ""); }
    }).catch(() => { if (token === previewRequest.current && store.path === repo) setPreviewError(t("The branch summary could not be read. Refresh and try again.")); })
      .finally(() => { if (token === previewRequest.current) setPreviewLoading(false); }), 250);
    return () => { clearTimeout(timer); ++previewRequest.current; };
  }, [repo, base, store.headHash, store.repoState, previewSource]);

  const prepare = async () => {
    if (!repo || !validRevisionInput(start)) return;
    const token = ++request.current; setPlanning(true); setError(null);
    try {
      const sha = (await git(["rev-parse", "--verify", start + "^{commit}"], repo)).stdout.trim();
      if (!fullObjectID(sha) || store.path !== repo || token !== request.current) return;
      await store.startInteractiveRebase(sha, false);
      if (token === request.current && store.path === repo) setPlanKey((k) => k + 1);
    } catch (e) { if (token === request.current && store.path === repo) setError(describe(e)); } finally { if (token === request.current && store.path === repo) setPlanning(false); }
  };
  const dirty = !statusIsEmpty(store.status);
  const rebase = async () => {
    if (!repo || !validRevisionInput(base) || store.busy) return;
    const token = ++request.current, head = store.headHash, autostash = stash && dirty;
    try {
      const [target, actualHead] = await Promise.all([git(["rev-parse", "--verify", base + "^{commit}"], repo), git(["rev-parse", "--verify", "HEAD"], repo)]);
      const oid = target.stdout.trim(), original = actualHead.stdout.trim();
      if (store.path !== repo || token !== request.current || !fullObjectID(oid) || original !== head) return;
      store.ask({ title: t("Rebase the current branch?"), message: t("Commits from the current branch will be replayed onto '{0}'. Commit or stash your changes first. Review the result before pushing.", base) + "\n\n" + oid.slice(0, 12), actionTitle: t("Start rebase"), destructive: false, action: async () => {
        if (store.path !== repo || token !== request.current || store.headHash !== head) return;
        try { const current = (await git(["rev-parse", "--verify", "HEAD"], repo)).stdout.trim(); if (store.path === repo && token === request.current && current === original) await store.rebase(oid, autostash); } catch (e) { if (store.path === repo && token === request.current) setError(describe(e)); }
      } });
    } catch (e) { if (store.path === repo && token === request.current) setError(describe(e)); }
  };

  const chosen = bases.find((value) => value.name === base);
  // why Start is disabled, when uncommitted changes are the reason
  const blocked = dirty && !stash ? t("{0} uncommitted files. Stash them above or commit first.", changed(store)) : null;
  // the commits this branch has on top of the chosen base, or its latest ones when there is no base to compare with
  const cleanupCommits = preview?.commits.length ? preview.commits : store.entries.slice(0, 30).map(({ commit }) => ({ id: commit.id, subject: commit.subject })).filter((commit) => fullObjectID(commit.id));
  const target = mode === "cleanup" ? t("Clean up history") : base || t("choose a new base");

  return (
    <section className="rebase-page">
      <header className="rebase-head">
        <span className="rebase-route"><strong className="ellipsis">{store.headBranch ?? t("Detached HEAD")}</strong><span aria-hidden>→</span><span className="ellipsis">{target}</span></span>
        <div role="group" aria-label={t("Rebase mode")}>
          <Segmented value={mode} onChange={setMode} options={[{ value: "move", label: t("Move onto another branch") }, { value: "cleanup", label: t("Clean up history") }]} />
        </div>
      </header>
      {store.repoState !== "clean" ? (
        <div className="rebase-operation">
          <h3>{t("A Git operation is in progress.")}</h3>
          <span className="rebase-cap">{t("Resolve conflicts in Changes, then continue. Abort returns to the state before the operation.")}</span>
          <div className="row"><Button kind="primary" disabled={!!store.busy} onClick={() => void store.continueOperation()}>{t("Continue")}</Button><Button disabled={!!store.busy} onClick={() => store.abortOperation()}>{t("Abort…")}</Button></div>
        </div>
      ) : (
        <div className="rebase-body">
          <section className="rebase-column">
            {mode === "move" ? <>
              <div className="rebase-step-title"><span className="rebase-num" aria-hidden>1</span><h3>{t("Choose the new base")}</h3></div>
              <span className="rebase-cap">{t("Replays this branch's commits on top of a new base, as if the branch had started there.")}</span>
              <label className="rebase-search"><Search size={13} /><input aria-label={t("Search branches and tags")} placeholder={t("Search branches and tags")} value={search} onChange={(event) => setSearch(event.target.value)} /></label>
              <div role="listbox" aria-label={t("New base")} className="rebase-options">
                {bases.filter((value) => rebaseBaseMatches(value, search)).map((value) => {
                  const selected = value.name === base, disabled = value.incoming === 0;
                  return (
                    <button key={value.kind + ":" + value.name} role="option" aria-selected={selected} aria-disabled={disabled} disabled={disabled} className={`rebase-option${selected ? " selected" : ""}`} onClick={() => setBase(value.name)}>
                      {value.kind === "remote" ? <Cloud size={13} /> : value.kind === "tag" ? <Tag size={13} /> : <GitBranch size={13} />}
                      <span className="rebase-option-name ellipsis">{value.name}</span>
                      {value.incoming !== null && <span className="rebase-option-note">{value.incoming === 0 ? t("Already in this branch") : t("{0} new commits", value.incoming)}</span>}
                    </button>
                  );
                })}
              </div>
            </> : <>
              <div className="rebase-step-title"><span className="rebase-num" aria-hidden>1</span><h3>{t("First commit to include")}</h3></div>
              <span className="rebase-cap">{t("Choose the oldest commit to include. Review actions and execution order before starting.")}</span>
              <div role="listbox" aria-label={t("First commit to include")} className="rebase-options">
                {cleanupCommits.map((commit) => (
                  <button key={commit.id} role="option" aria-selected={start === commit.id} className={`rebase-option${start === commit.id ? " selected" : ""}`} onClick={() => setStart(commit.id)}>
                    <code>{commit.id.slice(0, 7)}</code><span className="rebase-option-name ellipsis">{commit.subject}</span>
                  </button>
                ))}
              </div>
            </>}
          </section>
          <div className="rebase-detail">
            {mode === "move" ? <>
              <Step number={2} title={t("Review the commits")}>
                {previewLoading ? <span className="rebase-cap row"><Spinner size={14} />{t("Reading branch summary…")}</span>
                  : preview ? (!preview.replay ? <span className="rebase-cap">{t("No commits need to be replayed onto this base.")}</span> : <>
                    <span className="rebase-cap">{t("{0} commits replay on top of {1}, newest first.", preview.replay, base)}</span>
                    <ol className="rebase-commits" aria-label={t("Commits to replay")}>
                      {preview.commits.map((commit) => <li key={commit.id}><code>{commit.id.slice(0, 7)}</code><span className="ellipsis">{commit.subject}</span>{commit.date != null && <span className="rebase-cap">{shortDate(commit.date)}</span>}</li>)}
                    </ol>
                  </>)
                  : <span className="rebase-cap">{previewError ?? t("Choose a base to see the commits that replay.")}</span>}
              </Step>
              <Step number={3} title={t("Start")} last>
                <Checkbox checked={stash} onChange={setStash} label={t("Stash uncommitted changes and restore them after")} />
                <div className="rebase-start">
                  <div className="row">
                    <Button kind="primary" disabled={!validRevisionInput(base) || chosen?.incoming === 0 || preview?.replay === 0 || !!store.busy || !store.headBranch || !!blocked} onClick={() => void rebase()}>{t("Start rebase")}</Button>
                    <Button onClick={() => { store.navigate("repository"); store.select({ kind: "wip" }); }}>{t("Open changes")}</Button>
                  </div>
                  {/* the icon and the sentence carry the warning, not the colour alone */}
                  {blocked && <span className="rebase-reason status-tone" data-tone="waiting"><TriangleAlert size={14} aria-hidden />{blocked}</span>}
                </div>
                {error && <div className="error-text" role="alert">{error}</div>}
                <span className="rebase-cap">{t("Conflicts pause the rebase until you continue or abort, and a finished rebase can be undone.")}</span>
              </Step>
            </> : (
              <Step number={2} title={t("Clean up commit history")} last>
                <div className="row"><Button kind="primary" disabled={!validRevisionInput(start) || planning || !!store.busy || !store.headBranch} onClick={() => void prepare()}>{t("Build cleanup plan")}</Button>{planning && <Spinner size={14} />}</div>
                {error && <div className="error-text" role="alert">{error}</div>}
                {store.rebasePlan && <div className="rebase-plan"><InteractiveRebaseSheet key={planKey} store={store} embedded close={() => { store.rebasePlan = null; store.changed(); }} /></div>}
              </Step>
            )}
          </div>
        </div>
      )}
    </section>
  );
}
