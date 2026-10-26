import { useEffect, useRef, useState } from "react";
import { Folder, File, Search } from "lucide-react";
import { validRevisionInput, fullObjectID, loadRepositoryBlob, loadRepositoryTree, initialRepositoryFile, repositoryFolderCount, defaultRebaseBase, loadRebasePreview, statusIsEmpty, type RebasePreview, type RepositoryBlob, type RepositoryTree, type RepositoryTreeEntry } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { CompareRevisionsSheet } from "@/features/history-tools";
import { InteractiveRebaseSheet } from "@/features/interactive-rebase";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { describe, git } from "@/shared/platform";
import { Button, Empty, Spinner } from "@/shared/ui";
import "./local-workbench.css";

type Props = { store: RepoStore };
const refs = (store: RepoStore) => [...store.localBranches.map((b) => b.name), ...store.remoteBranches.map((b) => b.name), ...store.tags.map((b) => b.name)];
function Heading({ title, detail }: { title: string; detail: string }) { return <div className="workbench-heading"><h2>{t(title)}</h2><span className="hint">{t(detail)}</span></div>; }

export function RevisionComparisonPanel({ store }: Props) {
  useObserve(store);
  useEffect(() => () => store.cancelHistoryTools(), [store]);
  return <section className="local-workbench"><Heading title="Compare revisions" detail="Inspect the complete change between branches, tags or commits." /><CompareRevisionsSheet store={store} close={() => {}} embedded /></section>;
}

export interface RepositoryCodeSource { tree: typeof loadRepositoryTree; blob: typeof loadRepositoryBlob; read: (args: string[], repo: string) => Promise<string> }
const defaultCodeSource: RepositoryCodeSource = { tree: loadRepositoryTree, blob: loadRepositoryBlob, read: async (args, repo) => (await git(args, repo)).stdout };
export function RepositoryCodePanel({ store, source = defaultCodeSource }: Props & { source?: RepositoryCodeSource }) {
  useObserve(store);
  const [directory, setDirectory] = useState(""), [input, setInput] = useState("HEAD"), [query, setQuery] = useState(""), [tree, setTree] = useState<RepositoryTree | null>(null), [selected, setSelected] = useState<RepositoryTreeEntry | null>(null), [blob, setBlob] = useState<RepositoryBlob | null>(null), [mode, setMode] = useState("Source"), [aux, setAux] = useState(""), [loading, setLoading] = useState(false), [error, setError] = useState<string | null>(null);
  const request = useRef(0), fileRequest = useRef(0), repo = store.path;
  const load = async (ref = input) => { if (!repo) return; const token = ++request.current; ++fileRequest.current; setLoading(true); setError(null); setTree(null); setDirectory(""); setSelected(null); setBlob(null); setAux(""); try { const value = await source.tree(repo, ref); if (token === request.current && store.path === repo) {
    setTree(value); const initial=initialRepositoryFile(value.entries);
    if(initial){const fileToken=++fileRequest.current;setSelected(initial);setMode("Source");const parent=initial.path.split("/").slice(0,-1).join("/");setDirectory(parent);const preview=await source.blob(repo,initial);if(token===request.current&&fileToken===fileRequest.current&&store.path===repo)setBlob(preview);}
  } } catch (e) { if (token === request.current && store.path === repo) setError(describe(e)); } finally { if (token === request.current && store.path === repo) setLoading(false); } };
  useEffect(() => { setInput("HEAD"); setQuery(""); void load("HEAD"); return () => { ++request.current; ++fileRequest.current; }; }, [repo, source]);
  const open = async (entry: RepositoryTreeEntry, view = "Source") => {
    if (!repo || !tree) return; const token = ++fileRequest.current, snapshot = tree; setSelected(entry); setMode(view); setBlob(null); setAux(""); setError(null);
    try {
      if (view === "Source") { const value = await source.blob(repo, entry); if (token === fileRequest.current && snapshot === tree && store.path === repo) setBlob(value); }
      else { let lineCount = 1; if (view === "Blame") { const preview = await source.blob(repo, entry); if (!preview.text) { if (token === fileRequest.current && store.path === repo) setAux(preview.notice ?? t("No content to show.")); return; } lineCount = Math.max(1, Math.min(5000, preview.text.split("\n").length - (preview.text.endsWith("\n") ? 1 : 0))); } const args = view === "File history" ? ["log", "--follow", "-n", "100", "--date=short", "--format=%h %ad %an%n%s%n", snapshot.revision, "--", entry.path] : view === "Working changes" ? ["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", entry.path] : ["blame", "--date=short", "-L", `1,${lineCount}`, snapshot.revision, "--", entry.path]; const result = await source.read(args, repo); if (token === fileRequest.current && store.path === repo) setAux(result.slice(0, 2_000_000)); }
    } catch (e) { if (token === fileRequest.current && store.path === repo) setError(describe(e)); }
  };
  const allEntries = tree?.entries ?? [], prefix = directory ? directory + "/" : "";
  const folders = query ? [] : [...new Set(allEntries.filter((entry) => entry.path.startsWith(prefix) && entry.path.slice(prefix.length).includes("/")).map((entry) => prefix + entry.path.slice(prefix.length).split("/")[0]))].sort();
  const entries = allEntries.filter((entry) => query ? entry.path.toLowerCase().includes(query.toLowerCase()) : entry.path.startsWith(prefix) && !entry.path.slice(prefix.length).includes("/")), visible = entries.slice(0, 2000);
  return <section className="local-workbench"><Heading title="Code" detail="Browse committed files at a fixed branch, tag or commit. Your working files stay untouched." /><div className="row workbench-controls"><input aria-label={t("Revision")} className="input grow workbench-revision" value={input} onChange={(e) => setInput(e.target.value)} list="code-revisions"/><datalist id="code-revisions">{refs(store).map((name) => <option key={name} value={name}/>)}</datalist><Button kind="primary" disabled={loading} onClick={() => void load()}>{t("Load revision")}</Button><Search size={15}/><input aria-label={t("Search files")} placeholder={t("Search files")} className="input workbench-search" value={query} onChange={(e) => setQuery(e.target.value)}/></div>
    {loading && <Spinner/>}{error && <div role="alert" className="error-text">{error}</div>}{tree && <div className="hint mono">{tree.revision.slice(0,12)} · {t("{0} files · {1} folders",tree.entries.length,repositoryFolderCount(tree.entries))}{tree.truncated ? ` · ${t("File list truncated. Narrow the repository or use another tool for the remaining files.")}` : ""}</div>}
    <div className="workbench-code-layout"><nav className="workbench-file-tree" aria-label={t("Repository files")}><div className="workbench-breadcrumb"><button onClick={() => setDirectory("")}>{t("Repository")}</button>{directory.split("/").filter(Boolean).map((part, i, list) => <button key={i} onClick={() => setDirectory(list.slice(0, i + 1).join("/"))}>/ {part}</button>)}</div>{folders.map((folder) => <button key={folder} onClick={() => setDirectory(folder)}><Folder size={15}/><span>{folder.slice(prefix.length)}</span></button>)}{visible.map((entry) => <button key={entry.path} className={selected?.path === entry.path ? "on" : ""} onClick={() => void open(entry)} title={entry.path}><File size={14}/><span>{query ? entry.path : entry.path.slice(prefix.length)}</span><span className="hint">{entry.kind === "file" ? "" : entry.kind === "symlink" ? "↪" : "⊞"}</span></button>)}{entries.length > visible.length && <p className="hint">{t("Showing the first 2,000 matches. Search to narrow the file list.")}</p>}{tree && !entries.length && !folders.length && <Empty title={t("No matching files")}/>}</nav><div className="workbench-code-content">{selected ? <><div className="row workbench-code-toolbar"><strong className="grow ellipsis" title={selected.path}>{selected.path}</strong><span className="hint">{selected.size.toLocaleString()} B</span></div><div className="row workbench-tabs">{["Source", "File history", "Blame", "Working changes"].map((view) => <Button key={view} kind={mode === view ? "primary" : undefined} disabled={selected.kind !== "file" && view !== "Source"} onClick={() => void open(selected, view)}>{t(view)}</Button>)}</div>{blob?.notice && <p className="hint">{blob.notice}</p>}{blob?.image ? <div className="workbench-image"><img src={blob.image} alt={selected.path}/></div> : <pre className="workbench-source" tabIndex={0}>{mode === "Source" ? blob?.text ?? (blob?.notice ? "" : t("Loading…")) : aux || t("No content to show.")}</pre>}</> : <Empty title={t("Choose a file")} detail={t("Search paths or choose a file from the repository tree.")}/>}</div></div>
  </section>;
}

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
  return <section className="local-workbench"><Heading title="Rebase" detail="Move the current branch onto a new base, or review and reorder its commits."/><div className="hint">{t("Current branch")}: <strong>{store.headBranch ?? t("Detached HEAD")}</strong></div>
    {store.repoState !== "clean" ? <div className="workbench-operation col"><strong>{t("A Git operation is in progress.")}</strong><span className="hint">{t("Resolve conflicts in Changes, then continue. Abort returns to the state before the operation.")}</span><div className="row"><Button disabled={!!store.busy} onClick={() => void store.continueOperation()}>{t("Continue")}</Button><Button disabled={!!store.busy} onClick={() => store.abortOperation()}>{t("Abort…")}</Button></div></div> : <><div className="workbench-card"><h3>{t("Change branch base")}</h3><div className="row"><input aria-label={t("New base revision")} className="input grow" value={base} onChange={(e) => setBase(e.target.value)} list="rebase-refs"/><Button disabled={!validRevisionInput(base) || !!store.busy || !store.headBranch || !statusIsEmpty(store.status)} onClick={() => void rebase()}>{t("Start rebase")}</Button></div></div>{previewPanel}<div className="workbench-card"><h3>{t("Clean up commit history")}</h3><p className="hint">{t("Choose the oldest commit to include. Review actions and execution order before starting.")}</p><div className="row"><input aria-label={t("First commit to include")} placeholder={t("First commit to include")} className="input grow" value={start} onChange={(e) => setStart(e.target.value)} list="rebase-commits"/><Button disabled={!start.trim() || planning || !!store.busy || !store.headBranch} onClick={() => void prepare()}>{planning ? <Spinner size={14}/> : t("Build cleanup plan")}</Button></div><datalist id="rebase-commits">{store.entries.filter((e) => fullObjectID(e.commit.id)).map((e) => <option key={e.commit.id} value={e.commit.id}>{e.commit.subject}</option>)}</datalist></div></>}
    {!statusIsEmpty(store.status)&&store.repoState==="clean"&&<div className="workbench-dirty-note"><span>{t("Commit or stash working changes before starting rebase.")}</span><Button size="small" onClick={()=>{store.navigate("repository");store.select({kind:"wip"});}}>{t("Open Changes")}</Button></div>}
    <datalist id="rebase-refs">{refs(store).map((name) => <option key={name} value={name}/>)}</datalist>{error && <div className="error-text" role="alert">{error}</div>}{store.rebasePlan && <div className="workbench-plan"><InteractiveRebaseSheet key={planKey} store={store} embedded close={() => { store.rebasePlan = null; store.changed(); }}/></div>}
    <div className="hint">{t("After rebase, compare the branch with its base and check the rewritten commits before pushing. Push review checks the destination and any force push.")}</div><Button disabled={!validRevisionInput(base)} onClick={() => { store.historyTools.left = base; store.historyTools.right = "HEAD"; store.historyTools.useMergeBase = false; store.changed(); setComparing(true); void store.loadRevisionComparison(); }}>{t("Compare branch with base")}</Button>{comparing && <CompareRevisionsSheet store={store} close={() => setComparing(false)} embedded/>}
  </section>;
}
