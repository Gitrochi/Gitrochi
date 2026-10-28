import { useEffect, useId, useMemo, useRef, useState } from "react";
import { ArrowDown, ArrowUp, CaseSensitive, Check, ChevronRight, Code2, Copy, File, Folder, GitBranch, History, PanelLeftClose, PanelLeftOpen, Search, WrapText } from "lucide-react";
import { initialRepositoryFile, loadRepositoryBlob, loadRepositoryTree, repositoryFolderCount, type RepositoryBlob, type RepositoryTree, type RepositoryTreeEntry } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { describe, git } from "@/shared/platform";
import { Button, Empty, IconButton, Spinner } from "@/shared/ui";
import { sourceLanguage, sourceLineCount, sourceMatches, sourceMatchLimit, wrappingLineLimit } from "../lib/source-reader";
import { RepositorySourceView } from "./RepositorySourceView";
import "./repository-code.css";

export interface RepositoryCodeSource { tree: typeof loadRepositoryTree; blob: typeof loadRepositoryBlob; read: (args: string[], repo: string) => Promise<string> }
const defaultCodeSource: RepositoryCodeSource = { tree: loadRepositoryTree, blob: loadRepositoryBlob, read: async (args, repo) => (await git(args, repo)).stdout };
const modes = ["Source", "File history", "Blame", "Working changes"];

/** Read committed files with revision context and local reading controls. */
export function RepositoryCodePanel({ store, source = defaultCodeSource }: { store: RepoStore; source?: RepositoryCodeSource }) {
  useObserve(store);
  const [directory, setDirectory] = useState(""), [input, setInput] = useState("HEAD"), [query, setQuery] = useState("");
  const [tree, setTree] = useState<RepositoryTree | null>(null), [selected, setSelected] = useState<RepositoryTreeEntry | null>(null), [blob, setBlob] = useState<RepositoryBlob | null>(null);
  const [mode, setMode] = useState("Source"), [aux, setAux] = useState(""), [loading, setLoading] = useState(false), [fileLoading, setFileLoading] = useState(false), [error, setError] = useState<string | null>(null);
  const [find, setFind] = useState(""), [activeMatch, setActiveMatch] = useState(0), [wrap, setWrap] = useState(false), [fontSize, setFontSize] = useState(13), [explorer, setExplorer] = useState(true), [copied, setCopied] = useState(false);
  const request = useRef(0), fileRequest = useRef(0), copyTimer = useRef<ReturnType<typeof setTimeout>>(), findInput = useRef<HTMLInputElement>(null), repo = store.path, revisionList = useId();
  const refs = [...store.localBranches, ...store.remoteBranches, ...store.tags].map((ref) => ref.name);
  const readFile = async (entry: RepositoryTreeEntry, snapshot: RepositoryTree, view = "Source") => {
    if (!repo) return;
    const token = ++fileRequest.current, treeToken = request.current;
    const current = () => token === fileRequest.current && treeToken === request.current && store.path === repo;
    setSelected(entry); setDirectory(entry.path.split("/").slice(0, -1).join("/")); setMode(view); setBlob(null); setAux(""); setError(null); setFileLoading(true); setCopied(false); setActiveMatch(0);
    try {
      if (view === "Source") {
        const value = await source.blob(repo, entry);
        if (current()) setBlob(value);
      } else {
        let lineCount = 1;
        if (view === "Blame") {
          const preview = await source.blob(repo, entry);
          if (!current()) return;
          if (!preview.text) { setAux(preview.notice ?? t("No content to show.")); return; }
          lineCount = Math.max(1, Math.min(5000, sourceLineCount(preview.text)));
        }
        if (!current()) return;
        const args = view === "File history" ? ["log", "--follow", "-n", "100", "--date=short", "--format=%h %ad %an%n%s%n", snapshot.revision, "--", entry.path]
          : view === "Working changes" ? ["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", entry.path]
          : ["blame", "--date=short", "-L", `1,${lineCount}`, snapshot.revision, "--", entry.path];
        const result = await source.read(args, repo);
        if (current()) setAux(result.slice(0, 2_000_000));
      }
    } catch (cause) { if (current()) setError(describe(cause)); }
    finally { if (current()) setFileLoading(false); }
  };
  const load = async (ref = input) => {
    if (!repo) return;
    const token = ++request.current; ++fileRequest.current;
    setLoading(true); setFileLoading(false); setError(null); setTree(null); setDirectory(""); setSelected(null); setBlob(null); setAux("");
    try {
      const value = await source.tree(repo, ref);
      if (token !== request.current || store.path !== repo) return;
      setTree(value); setLoading(false);
      const initial = initialRepositoryFile(value.entries);
      if (initial) { setDirectory(initial.path.split("/").slice(0, -1).join("/")); await readFile(initial, value); }
    } catch (cause) { if (token === request.current && store.path === repo) setError(describe(cause)); }
    finally { if (token === request.current && store.path === repo) setLoading(false); }
  };
  useEffect(() => {
    setInput("HEAD"); setQuery(""); setFind(""); void load("HEAD");
    return () => { ++request.current; ++fileRequest.current; clearTimeout(copyTimer.current); };
  }, [repo, source]);
  const allEntries = tree?.entries ?? [], prefix = directory ? directory + "/" : "";
  const folders = useMemo(() => query ? [] : [...new Set(allEntries.filter((entry) => entry.path.startsWith(prefix) && entry.path.slice(prefix.length).includes("/")).map((entry) => prefix + entry.path.slice(prefix.length).split("/")[0]))].sort(), [allEntries, query, prefix]);
  const entries = useMemo(() => allEntries.filter((entry) => query ? entry.path.toLocaleLowerCase().includes(query.toLocaleLowerCase()) : entry.path.startsWith(prefix) && !entry.path.slice(prefix.length).includes("/")), [allEntries, query, prefix]);
  const text = mode === "Source" ? blob?.text ?? "" : aux;
  const language = mode === "Source" && selected ? sourceLanguage(selected.path) : "Plain text";
  const lineCount = useMemo(() => sourceLineCount(text), [text]);
  const matches = useMemo(() => sourceMatches(text, find), [text, find]);
  const matchIndex = matches.length ? activeMatch % matches.length : 0;
  const folderCount = useMemo(() => repositoryFolderCount(allEntries), [allEntries]);
  const moveMatch = (delta: number) => setActiveMatch((value) => matches.length ? (value + delta + matches.length) % matches.length : 0);
  const copy = async () => {
    const token = fileRequest.current, treeToken = request.current;
    const current = () => token === fileRequest.current && treeToken === request.current && store.path === repo;
    try { await navigator.clipboard.writeText(text); if (current()) { setCopied(true); clearTimeout(copyTimer.current); copyTimer.current = setTimeout(() => setCopied(false), 1800); } }
    catch (cause) { if (current()) setError(describe(cause)); }
  };
  return <section className="repository-code" onKeyDown={(event) => { if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f" && selected && !blob?.image) { event.preventDefault(); findInput.current?.focus(); findInput.current?.select(); } }}>
    <header className="code-revision-bar">
      <div className="code-revision-field"><GitBranch size={15}/><input aria-label={t("Revision")} value={input} onChange={(event) => setInput(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") void load(); }} list={revisionList}/><datalist id={revisionList}>{[...new Set(refs)].map((name) => <option key={name} value={name}/>)}</datalist></div>
      <Button size="small" disabled={loading} onClick={() => void load()}>{t("Load revision")}</Button>
      <span className="code-revision-summary">{loading ? <Spinner/> : tree && <><span>{t("{0} files · {1} folders", tree.entries.length.toLocaleString(), folderCount.toLocaleString())}</span><code title={tree.revision}>{tree.revision.slice(0, 8)}</code></>}</span>
      <IconButton tip={t(explorer ? "Hide file explorer" : "Show file explorer")} aria-label={t(explorer ? "Hide file explorer" : "Show file explorer")} aria-pressed={explorer} onClick={() => setExplorer((value) => !value)} icon={explorer ? <PanelLeftClose size={16}/> : <PanelLeftOpen size={16}/>} />
    </header>
    {error && <div role="alert" className="code-notice error-text">{error}</div>}
    {tree?.truncated && <div className="code-notice hint">{t("File list truncated. Narrow the repository or use another tool for the remaining files.")}</div>}
    <div className={`code-reader-layout ${explorer ? "" : "focused"}`}>
      {explorer && <nav className="code-explorer" aria-label={t("Repository files")}>
        <div className="code-explorer-heading"><strong>{t("Files")}</strong><span>{allEntries.length.toLocaleString()}</span></div>
        <label className="code-search"><Search size={14}/><input aria-label={t("Search files")} placeholder={t("Search files")} value={query} onChange={(event) => setQuery(event.target.value)}/></label>
        <div className="code-breadcrumb"><button onClick={() => { setDirectory(""); setQuery(""); }}>{t("Repository")}</button>{directory.split("/").filter(Boolean).map((part, i, list) => <span key={i}><ChevronRight size={11}/><button onClick={() => { setDirectory(list.slice(0, i + 1).join("/")); setQuery(""); }}>{part}</button></span>)}</div>
        <div className="code-file-list">{folders.map((folder) => <button className="code-file-row folder" key={folder} onClick={() => setDirectory(folder)}><Folder size={15}/><span>{folder.slice(prefix.length)}</span><ChevronRight size={12}/></button>)}
          {entries.slice(0, 2000).map((entry) => <button key={entry.path} className={`code-file-row ${selected?.path === entry.path ? "on" : ""}`} aria-current={selected?.path === entry.path ? "true" : undefined} onClick={() => { if (tree) void readFile(entry, tree); }} title={entry.path}><File size={14}/><span>{query ? entry.path : entry.path.slice(prefix.length)}</span>{entry.kind !== "file" && <span className="code-entry-kind">{entry.kind === "symlink" ? "↪" : "⊞"}</span>}</button>)}
          {entries.length > 2000 && <p className="hint">{t("Showing the first 2,000 matches. Search to narrow the file list.")}</p>}{tree && !entries.length && !folders.length && <Empty title={t("No matching files")}/>}
        </div>
      </nav>}
      <main className="code-document">{selected ? <>
        <div className="code-document-heading"><span className="code-file-emblem"><Code2 size={18}/></span><div className="code-file-identity"><strong title={selected.path}>{selected.path.split("/").at(-1)}</strong><span title={selected.path}>{selected.path}</span></div><span className="code-file-size">{selected.size.toLocaleString()} B</span></div>
        <div className="code-mode-bar" role="group" aria-label={t("Source")}>{modes.map((view) => <button key={view} aria-pressed={mode === view} className={mode === view ? "on" : ""} disabled={selected.kind !== "file" && view !== "Source"} onClick={() => { if (tree) void readFile(selected, tree, view); }}>{view === "Source" && <Code2 size={13}/>} {view === "File history" && <History size={13}/>} {t(view)}</button>)}</div>
        {!blob?.image && <div className="code-reading-tools"><label className="code-search code-find"><Search size={14}/><input ref={findInput} aria-label={t("Find in file")} placeholder={t("Find in file")} value={find} disabled={fileLoading} onChange={(event) => { setFind(event.target.value); setActiveMatch(0); }} onKeyDown={(event) => { if (event.key === "Enter") moveMatch(event.shiftKey ? -1 : 1); if (event.key === "Escape") setFind(""); }}/>{find && <span className="code-match-count" role="status">{matches.length ? t("{0} of {1}", matchIndex + 1, matches.length === sourceMatchLimit ? `${sourceMatchLimit.toLocaleString()}+` : matches.length) : t("No matches")}</span>}</label>
          <div className="code-tool-group"><IconButton small icon={<ArrowUp size={14}/>} aria-label={t("Previous match")} tip={t("Previous match")} disabled={!matches.length} onClick={() => moveMatch(-1)}/><IconButton small icon={<ArrowDown size={14}/>} aria-label={t("Next match")} tip={t("Next match")} disabled={!matches.length} onClick={() => moveMatch(1)}/></div>
          <div className="code-tool-group code-display-tools"><IconButton small icon={<WrapText size={15}/>} aria-label={t("Wrap lines")} aria-pressed={wrap} tip={t(lineCount > wrappingLineLimit ? "Wrapping is unavailable for files with more than 5,000 lines." : "Wrap lines")} disabled={lineCount > wrappingLineLimit} className={wrap ? "on" : ""} onClick={() => setWrap((value) => !value)}/><IconButton small icon={<span className="code-font-adjust">A−</span>} aria-label={t("Decrease font size")} tip={t("Decrease font size")} disabled={fontSize <= 11} onClick={() => setFontSize((value) => Math.max(11, value - 1))}/><IconButton small icon={<CaseSensitive size={18}/>} aria-label={t("Increase font size")} tip={t("Increase font size")} disabled={fontSize >= 20} onClick={() => setFontSize((value) => Math.min(20, value + 1))}/><IconButton small icon={copied ? <Check size={14}/> : <Copy size={14}/>} aria-label={t(copied ? "Copied" : "Copy source")} tip={t(copied ? "Copied" : "Copy source")} disabled={!text || fileLoading} onClick={() => void copy()}/></div>
        </div>}
        {blob?.notice && <p className="code-notice hint">{blob.notice}</p>}
        {fileLoading ? <div className="code-loading" role="status"><Spinner/>{t("Loading…")}</div> : blob?.image ? <div className="code-image"><img src={blob.image} alt={selected.path}/></div> : text ? <RepositorySourceView text={text} language={language} fontSize={fontSize} wrap={wrap} matches={matches} activeMatch={matchIndex} lineCount={lineCount}/> : <div className="code-empty-content hint">{blob?.notice ? "" : t("No content to show.")}</div>}
        <footer className="code-status-bar"><span><span className="code-status-dot"/>{t("Read only")}</span><span>{language === "Plain text" ? t(language) : language}</span>{!blob?.image && <span>{t("{0} lines", lineCount.toLocaleString())}</span>}<code title={tree?.revision}>{mode === "Working changes" ? t("Working changes") : tree?.revision.slice(0, 8)}</code></footer>
      </> : <div className="code-empty-content">{loading ? <Spinner/> : <Empty title={t("Choose a file")} detail={t("Search paths or choose a file from the repository tree.")}/>}</div>}</main>
    </div>
  </section>;
}
