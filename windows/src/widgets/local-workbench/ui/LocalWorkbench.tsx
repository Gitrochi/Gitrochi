import { useEffect, useRef, useState } from "react";
import { validRevisionInput, fullObjectID, defaultRebaseBase, loadRebasePreview, statusIsEmpty, type RebasePreview } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { CompareRevisionsSheet } from "@/features/history-tools";
import { InteractiveRebaseSheet } from "@/features/interactive-rebase";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { describe, git } from "@/shared/platform";
import { Button, Spinner } from "@/shared/ui";
import "./local-workbench.css";

type Props = { store: RepoStore };
const refs = (store: RepoStore) => [...store.localBranches.map((b) => b.name), ...store.remoteBranches.map((b) => b.name), ...store.tags.map((b) => b.name)];

export function RebaseWorkbenchPanel({ store, previewSource=loadRebasePreview }: Props & {previewSource?: typeof loadRebasePreview}) {
  useObserve(store);
  const [base, setBase] = useState(defaultRebaseBase(refs(store),store.headBranch,store.status.upstream)), [start, setStart] = useState(""), [planning, setPlanning] = useState(false), [error, setError] = useState<string | null>(null), [planKey, setPlanKey] = useState(0), [comparing, setComparing] = useState(false);
  const request = useRef(0), previewRequest=useRef(0), repo = store.path;
  const [preview,setPreview]=useState<RebasePreview|null>(null),[previewLoading,setPreviewLoading]=useState(false),[previewError,setPreviewError]=useState<string|null>(null);
  useEffect(() => { setBase(defaultRebaseBase(refs(store),store.headBranch,store.status.upstream)); setStart(""); setError(null); return () => { ++request.current; }; }, [repo]);
  useEffect(()=>{
    const token=++previewRequest.current,head=store.headHash;setPreview(null);setPreviewError(null);setPreviewLoading(false);
    if(!repo||store.repoState!=="clean")return;
    if(!head){setPreviewError(t("Commit at least once to preview rebase."));return;}
    if(!validRevisionInput(base)){setPreviewError(t("Choose a valid base branch to preview its commits."));return;}
    setPreviewLoading(true);const timer=setTimeout(()=>void previewSource(repo,base,head).then(value=>{
      if(token===previewRequest.current&&store.path===repo&&store.headHash===head){setPreview(value);setStart(current=>current||value.commits.slice(0,6).at(-1)?.id||"");}
    }).catch(()=>{if(token===previewRequest.current&&store.path===repo)setPreviewError(t("The branch summary could not be read. Refresh and try again."));}).finally(()=>{if(token===previewRequest.current)setPreviewLoading(false);}),250);
    return()=>{clearTimeout(timer);++previewRequest.current;};
  },[repo,base,store.headHash,store.repoState,previewSource]);
  const prepare = async () => { if (!repo || !validRevisionInput(start)) return; const token = ++request.current; setPlanning(true); setError(null); try { const sha = (await git(["rev-parse", "--verify", start + "^{commit}"], repo)).stdout.trim(); if (!fullObjectID(sha) || store.path !== repo || token !== request.current) return; await store.startInteractiveRebase(sha, false); if (token === request.current && store.path === repo) setPlanKey((k) => k + 1); } catch (e) { if (token === request.current && store.path === repo) setError(describe(e)); } finally { if (token === request.current && store.path === repo) setPlanning(false); } };
  const rebase = async () => {
    if (!repo || !validRevisionInput(base) || store.busy) return;
    const token = ++request.current, head = store.headHash;
    try {
      const [target, actualHead] = await Promise.all([git(["rev-parse", "--verify", base + "^{commit}"], repo), git(["rev-parse", "--verify", "HEAD"], repo)]);
      const oid = target.stdout.trim(), original = actualHead.stdout.trim();
      if (store.path !== repo || token !== request.current || !fullObjectID(oid) || original !== head) return;
      store.ask({ title: t("Rebase the current branch?"), message: t("Commits from the current branch will be replayed onto '{0}'. Commit or stash your changes first. Review the result before pushing.", base) + "\n\n" + oid.slice(0, 12), actionTitle: t("Start rebase"), destructive: false, action: async () => {
        if (store.path !== repo || token !== request.current || store.headHash !== head) return;
        try { const current = (await git(["rev-parse", "--verify", "HEAD"], repo)).stdout.trim(); if (store.path === repo && token === request.current && current === original) await store.rebase(oid); } catch (e) { if (store.path === repo && token === request.current) setError(describe(e)); }
      } });
    } catch (e) { if (store.path === repo && token === request.current) setError(describe(e)); }
  };
  const previewPanel=<div className="workbench-rebase-preview"><div className="row"><strong>{t("Rebase preview")}</strong><span className="workbench-branch-chip" title={store.headBranch??""}>{store.headBranch??t("Detached HEAD")}</span><span aria-hidden>→</span><span className="workbench-branch-chip" title={base}>{base}</span></div>
    {previewLoading?<div className="row hint"><Spinner size={14}/>{t("Reading branch summary…")}</div>:preview?<><div className="row workbench-preview-counts"><strong>{t("{0} commits to replay",preview.replay)}</strong><span className="hint">{t("{0} commits on the base only",preview.incoming)}</span></div>{!preview.replay?<p className="hint">{t("No commits need to be replayed onto this base.")}</p>:<><p className="hint">{t("Select the oldest commit to include in a cleanup plan.")}</p><div className="workbench-rebase-candidates">{preview.commits.slice(0,6).map(commit=><button key={commit.id} className={start===commit.id?"selected":""} onClick={()=>setStart(commit.id)}><span className="workbench-candidate-mark">{start===commit.id?"●":"○"}</span><code>{commit.id.slice(0,8)}</code><span>{commit.subject}</span></button>)}</div>{preview.replay>Math.min(6,preview.commits.length)&&<span className="hint">{t("Showing the latest 6 candidate commits.")}</span>}</>}</>:previewError&&<p className="hint">{previewError}</p>}
    <p className="hint">{t("This preview only reads history. Starting rebase still requires confirmation.")}</p></div>;
  return <section className="local-workbench"><div className="hint">{t("Current branch")}: <strong>{store.headBranch ?? t("Detached HEAD")}</strong></div>
    {store.repoState !== "clean" ? <div className="workbench-operation col"><strong>{t("A Git operation is in progress.")}</strong><span className="hint">{t("Resolve conflicts in Changes, then continue. Abort returns to the state before the operation.")}</span><div className="row"><Button disabled={!!store.busy} onClick={() => void store.continueOperation()}>{t("Continue")}</Button><Button disabled={!!store.busy} onClick={() => store.abortOperation()}>{t("Abort…")}</Button></div></div> : <><div className="workbench-card"><h3>{t("Change branch base")}</h3><div className="row"><input aria-label={t("New base revision")} className="input grow" value={base} onChange={(e) => setBase(e.target.value)} list="rebase-refs"/><Button disabled={!validRevisionInput(base) || !!store.busy || !store.headBranch || !statusIsEmpty(store.status)} onClick={() => void rebase()}>{t("Start rebase")}</Button></div></div>{previewPanel}<div className="workbench-card"><h3>{t("Clean up commit history")}</h3><p className="hint">{t("Choose the oldest commit to include. Review actions and execution order before starting.")}</p><div className="row"><input aria-label={t("First commit to include")} placeholder={t("First commit to include")} className="input grow" value={start} onChange={(e) => setStart(e.target.value)} list="rebase-commits"/><Button disabled={!start.trim() || planning || !!store.busy || !store.headBranch} onClick={() => void prepare()}>{planning ? <Spinner size={14}/> : t("Build cleanup plan")}</Button></div><datalist id="rebase-commits">{store.entries.filter((e) => fullObjectID(e.commit.id)).map((e) => <option key={e.commit.id} value={e.commit.id}>{e.commit.subject}</option>)}</datalist></div></>}
    {!statusIsEmpty(store.status)&&store.repoState==="clean"&&<div className="workbench-dirty-note"><span>{t("Commit or stash working changes before starting rebase.")}</span><Button size="small" onClick={()=>{store.navigate("repository");store.select({kind:"wip"});}}>{t("Open Changes")}</Button></div>}
    <datalist id="rebase-refs">{refs(store).map((name) => <option key={name} value={name}/>)}</datalist>{error && <div className="error-text" role="alert">{error}</div>}{store.rebasePlan && <div className="workbench-plan"><InteractiveRebaseSheet key={planKey} store={store} embedded close={() => { store.rebasePlan = null; store.changed(); }}/></div>}
    <div className="hint">{t("After rebase, compare the branch with its base and check the rewritten commits before pushing. Push review checks the destination and any force push.")}</div><Button disabled={!validRevisionInput(base)} onClick={() => { store.historyTools.left = base; store.historyTools.right = "HEAD"; store.historyTools.useMergeBase = false; store.changed(); setComparing(true); void store.loadRevisionComparison(); }}>{t("Compare branch with base")}</Button>{comparing && <CompareRevisionsSheet store={store} close={() => setComparing(false)} embedded/>}
  </section>;
}
