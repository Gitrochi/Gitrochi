import { useEffect, useMemo, useRef, useState } from "react";
import { CaseSensitive, PanelLeftClose, PanelLeftOpen, WrapText } from "lucide-react";
import { ArrowDown, ArrowUp, Check, ChevronDown, ChevronLeft, ChevronRight, Cloud, Copy, CornerLeftUp, File, Folder, GitBranch, GitCommitHorizontal, Search, Tag, X } from "@/shared/icons";
import { fileHistoryFormat, initialRepositoryFile, loadRepositoryBlob, loadRepositoryTree, parseBlameAsync, parseFileHistoryAsync, StatusBadge, validRevisionInput, type BlameLine, type ChangeKind, type FileHistoryEntry, type RepositoryBlob, type RepositoryTree, type RepositoryTreeEntry } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { describe, git } from "@/shared/platform";
import { Button, Empty, IconButton, Markdown, Spinner, StatusPill } from "@/shared/ui";
import { sourceLanguage, sourceLineCount, sourceMatches, sourceMatchLimit, wrappingLineLimit } from "../lib/source-reader";
import { closeCodeFile, codeOutline, emptyCodeNavigation, stepCodeHistory, visitCodeLocation, type CodeNavigation, type CodeViewMode } from "../lib/code-navigation";
import { blameArgs, blameBefore, droppedFolders, fileHistoryArgs, historyCountLabel, localCommitArgs, revisionName } from "../lib/code-history";
import { CodePositionTools } from "./CodePositionTools";
import { CodeQuickOpen } from "./CodeQuickOpen";
import { RepositorySourceView } from "./RepositorySourceView";
import { CodeExternalEditors, type RepositoryEditorSource } from "./CodeExternalEditors";
import { RepositoryLanguages } from "./RepositoryLanguages";
import { RepositoryHTMLPreview } from "./RepositoryHTMLPreview";
import { CodeHistoryView } from "./CodeHistoryView";
import { CodeBlameView } from "./CodeBlameView";
import { CodeChangesView } from "./CodeChangesView";
import { formatRepositoryBytes, repositoryLanguage, summarizeRepositoryLanguages } from "../lib/repository-languages";
import "./repository-code.css";

export interface RepositoryCodeSource { tree: typeof loadRepositoryTree; blob: typeof loadRepositoryBlob; read: (args: string[], repo: string) => Promise<string> }
const defaultCodeSource: RepositoryCodeSource = { tree: loadRepositoryTree, blob: loadRepositoryBlob, read: async (args, repo) => (await git(args, repo)).stdout };
const modes: CodeViewMode[] = ["Source", "History", "Blame", "Working changes"];

/**
 * The Code page, as the redesign's Code boards draw it: one bar with the revision, back and forward, the file's path
 * and quick open; the folder's files in a column; and the open file under one row of view tabs (Source, History,
 * Blame, Working changes) with a status bar below. (macOS: RepositoryCodePanel)
 */
export function RepositoryCodePanel({ store, source = defaultCodeSource, editorSource }: { store: RepoStore; source?: RepositoryCodeSource; editorSource?: RepositoryEditorSource }) {
  useObserve(store);
  const [directory, setDirectory] = useState(""), [input, setInput] = useState("HEAD"), [revisionPicker, setRevisionPicker] = useState(false), [revisionSearch, setRevisionSearch] = useState("");
  const [tree, setTree] = useState<RepositoryTree | null>(null), [selected, setSelected] = useState<RepositoryTreeEntry | null>(null), [blob, setBlob] = useState<RepositoryBlob | null>(null);
  const [mode, setMode] = useState<CodeViewMode>("Source"), [loading, setLoading] = useState(false), [fileLoading, setFileLoading] = useState(false), [error, setError] = useState<string | null>(null);
  const [find, setFind] = useState(""), [activeMatch, setActiveMatch] = useState(0), [wrap, setWrap] = useState(false), [fontSize, setFontSize] = useState(13), [explorer, setExplorer] = useState(true), [copied, setCopied] = useState(false);
  const [navigation, setNavigation] = useState(emptyCodeNavigation), [quickOpen, setQuickOpen] = useState(false), [lineFocus, setLineFocus] = useState(0), [lineJump, setLineJump] = useState<{ line: number; id: number } | null>(null);
  const [languageFilter, setLanguageFilter] = useState<string | null>(null);
  // the commits that changed the open file, read once per file for the History tab and its count; null while reading
  const [history, setHistory] = useState<FileHistoryEntry[] | null>(null), [local, setLocal] = useState<ReadonlySet<string>>(new Set()), [historySelected, setHistorySelected] = useState<string | null>(null);
  const [blame, setBlame] = useState<BlameLine[] | null>(null);
  // lines of what the open view shows, for the status bar
  const [lines, setLines] = useState<number | null>(null), [pathWidth, setPathWidth] = useState(600);
  const navigationState = useRef(navigation), section = useRef<HTMLElement>(null), pathBar = useRef<HTMLElement>(null), revisionHost = useRef<HTMLDivElement>(null);
  const request = useRef(0), fileRequest = useRef(0), historyRequest = useRef(0), historyPath = useRef<string | null>(null), copyTimer = useRef<ReturnType<typeof setTimeout>>(), findInput = useRef<HTMLInputElement>(null), repo = store.path;
  const updateNavigation = (value: CodeNavigation) => { navigationState.current = value; setNavigation(value); };
  /** The commits that changed a file, for the History tab and its count, and which of them are not pushed yet */
  const readHistory = async (path: string, snapshot: RepositoryTree) => {
    if (!repo) return;
    const token = ++historyRequest.current, treeToken = request.current; historyPath.current = path;
    const current = () => token === historyRequest.current && treeToken === request.current && store.path === repo;
    setHistory(null); setLocal(new Set()); setHistorySelected(null);
    // stepping through files quickly must not start a log for each of them
    await new Promise((resolve) => setTimeout(resolve, 250));
    if (!current()) return;
    try {
      const entries = await parseFileHistoryAsync(await source.read(fileHistoryArgs(snapshot.revision, path, fileHistoryFormat), repo));
      if (!current()) return;
      setHistory(entries);
      // "local" means not on a remote, so it needs one
      if (!store.remoteBranches.length || !entries.length) return;
      const ids = await source.read(localCommitArgs(snapshot.revision), repo);
      if (current()) setLocal(new Set(ids.split(/\s+/).filter(Boolean)));
    } catch { if (current()) setHistory((value) => value ?? []); }
  };
  const readFile = async (entry: RepositoryTreeEntry, snapshot: RepositoryTree, view: CodeViewMode = "Source", recordHistory = true) => {
    if (!repo) return;
    const token = ++fileRequest.current, treeToken = request.current;
    const current = () => token === fileRequest.current && treeToken === request.current && store.path === repo;
    updateNavigation(visitCodeLocation(navigationState.current, { path: entry.path, mode: view }, recordHistory));
    if (languageFilter && repositoryLanguage(entry.path) !== languageFilter) setLanguageFilter(null);
    setSelected(entry); setDirectory(entry.path.split("/").slice(0, -1).join("/")); setMode(view); setBlob(null); setBlame(null); setLines(null); setError(null); setCopied(false); setActiveMatch(0); setLineJump(null);
    if (historyPath.current !== entry.path) void readHistory(entry.path, snapshot);
    // History and Working changes read for themselves
    if (view === "History" || view === "Working changes") { setFileLoading(false); return; }
    setFileLoading(true);
    try {
      const value = await source.blob(repo, entry);
      if (!current()) return;
      setBlob(value);
      const count = value.text ? sourceLineCount(value.text) : null;
      if (view !== "Blame") { setLines(count); return; }
      if (!count) { setBlame([]); return; }
      const parsed = await parseBlameAsync(await source.read(blameArgs(snapshot.revision, entry.path, count), repo));
      if (current()) { setBlame(parsed); setLines(parsed.length); }
    } catch (cause) { if (current()) setError(describe(cause)); }
    finally { if (current()) setFileLoading(false); }
  };
  const load = async (ref = input, reopen?: { path: string; mode: CodeViewMode }) => {
    if (!repo) return;
    const token = ++request.current; ++fileRequest.current; ++historyRequest.current; historyPath.current = null;
    updateNavigation(emptyCodeNavigation()); setQuickOpen(false); setRevisionPicker(false); setLineJump(null); setLanguageFilter(null); setInput(ref);
    setLoading(true); setFileLoading(false); setError(null); setTree(null); setDirectory(""); setSelected(null); setBlob(null); setBlame(null); setHistory(null); setLines(null);
    try {
      const value = await source.tree(repo, ref);
      if (token !== request.current || store.path !== repo) return;
      setTree(value); setLoading(false);
      const again = reopen && value.entries.find((entry) => entry.path === reopen.path), initial = again || initialRepositoryFile(value.entries);
      if (initial) { setDirectory(initial.path.split("/").slice(0, -1).join("/")); await readFile(initial, value, again ? reopen!.mode : "Source"); }
    } catch (cause) { if (token === request.current && store.path === repo) setError(describe(cause)); }
    finally { if (token === request.current && store.path === repo) setLoading(false); }
  };
  useEffect(() => {
    setFind(""); void load("HEAD");
    return () => { ++request.current; ++fileRequest.current; ++historyRequest.current; clearTimeout(copyTimer.current); };
  }, [repo, source]);
  useEffect(() => {
    section.current?.querySelector<HTMLElement>(".code-file-tab.on")?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [selected?.path, navigation.tabs]);
  useEffect(() => {
    const shortcut = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.shiftKey || event.altKey || !(event.ctrlKey || event.metaKey) || (event.target instanceof Element && event.target.closest(".xterm"))) return;
      if (!section.current?.getClientRects().length || (document.querySelector(".modal-backdrop") && !quickOpen)) return;
      if (event.key.toLowerCase() === "p" && tree) { event.preventDefault(); setQuickOpen((value) => !value); }
      if (event.key.toLowerCase() === "l" && selected && !blob?.image && mode === "Source") { event.preventDefault(); if (!quickOpen) setLineFocus((value) => value + 1); }
    };
    document.addEventListener("keydown", shortcut);
    return () => document.removeEventListener("keydown", shortcut);
  }, [tree, selected, blob?.image, quickOpen, mode]);
  useEffect(() => {
    const element = pathBar.current;
    if (!element) return;
    const observer = new ResizeObserver(() => setPathWidth(element.clientWidth));
    observer.observe(element); setPathWidth(element.clientWidth);
    return () => observer.disconnect();
  }, []);
  useEffect(() => {
    if (!revisionPicker) return;
    const close = (event: Event) => { if (event instanceof KeyboardEvent ? event.key === "Escape" : !revisionHost.current?.contains(event.target as Node)) setRevisionPicker(false); };
    document.addEventListener("mousedown", close); document.addEventListener("keydown", close);
    return () => { document.removeEventListener("mousedown", close); document.removeEventListener("keydown", close); };
  }, [revisionPicker]);
  const allEntries = tree?.entries ?? [], prefix = directory ? directory + "/" : "";
  const languageSummary = useMemo(() => summarizeRepositoryLanguages(allEntries), [allEntries]);
  const filteredEntries = useMemo(() => languageFilter ? allEntries.filter((entry) => entry.kind === "file" && repositoryLanguage(entry.path) === languageFilter) : allEntries, [allEntries, languageFilter]);
  const folders = useMemo(() => [...new Set(filteredEntries.filter((entry) => entry.path.startsWith(prefix) && entry.path.slice(prefix.length).includes("/")).map((entry) => prefix + entry.path.slice(prefix.length).split("/")[0]))].sort(), [filteredEntries, prefix]);
  const entries = useMemo(() => filteredEntries.filter((entry) => entry.path.startsWith(prefix) && !entry.path.slice(prefix.length).includes("/")), [filteredEntries, prefix]);
  // changed in the working tree and not committed yet
  const changed = new Map<string, ChangeKind>([...store.status.staged, ...store.status.unstaged, ...store.status.conflicted].map((file) => [file.path, file.kind]));
  const text = mode === "Source" || mode === "Preview" ? blob?.text ?? "" : "";
  const language = selected ? sourceLanguage(selected.path) : "Plain text", selectedLanguage = selected ? repositoryLanguage(selected.path) : "Other files";
  const canPreview = selected?.kind === "file" && /\.(?:html?|md|markdown)$/i.test(selected.path);
  const previewReader = useMemo(() => {
    const fileToken = fileRequest.current, treeToken = request.current;
    return async (entry: RepositoryTreeEntry): Promise<RepositoryBlob> => fileToken === fileRequest.current && treeToken === request.current && store.path === repo && repo ? source.blob(repo, entry) : {};
  }, [repo, source, tree, blob]);
  const lineCount = useMemo(() => sourceLineCount(text), [text]);
  const matches = useMemo(() => sourceMatches(text, find), [text, find]);
  const matchIndex = matches.length ? activeMatch % matches.length : 0;
  const symbols = useMemo(() => mode === "Source" ? codeOutline(text, language) : [], [text, language, mode]);
  const reading = !!selected && mode === "Source" && !blob?.image;
  const navigate = (delta: number) => {
    if (!tree) return;
    const moved = stepCodeHistory(navigationState.current, delta), entry = moved.location && allEntries.find((item) => item.path === moved.location!.path);
    if (!entry || !moved.location) return;
    updateNavigation(moved.state); void readFile(entry, tree, moved.location.mode, false);
  };
  const clearSelection = () => { ++fileRequest.current; ++historyRequest.current; historyPath.current = null; setSelected(null); setBlob(null); setBlame(null); setHistory(null); setLines(null); setFileLoading(false); setError(null); setLineJump(null); };
  const closeFile = (path: string) => {
    const result = closeCodeFile(navigationState.current, path, selected?.path ?? null); updateNavigation(result.state);
    if (path !== selected?.path) return;
    if (result.next && tree) { const entry = allEntries.find((item) => item.path === result.next!.path); if (entry) { void readFile(entry, tree, result.next.mode); return; } }
    clearSelection();
  };
  const moveMatch = (delta: number) => setActiveMatch((value) => matches.length ? (value + delta + matches.length) % matches.length : 0);
  const copy = async () => {
    const token = fileRequest.current, treeToken = request.current;
    const current = () => token === fileRequest.current && treeToken === request.current && store.path === repo;
    try { await navigator.clipboard.writeText(text); if (current()) { setCopied(true); clearTimeout(copyTimer.current); copyTimer.current = setTimeout(() => setCopied(false), 1800); } }
    catch (cause) { if (current()) setError(describe(cause)); }
  };
  /** "Blame before this change": the page moves to the commit's parent and blames the file there */
  const before = (commit: string) => {
    const target = history && blameBefore(commit, history.map((entry) => ({ id: entry.commit.id, parent: entry.commit.parents[0], path: entry.path })));
    return target ? () => void load(target.revision, { path: target.path, mode: "Blame" }) : null;
  };
  // the revision shown: its short hash and, when it has one, its name. No counts: the tabs and lists own those.
  const hash = tree?.revision.slice(0, 7) ?? "", name = tree ? revisionName(input, tree.revision, store.headBranch) : null, typed = revisionSearch.trim();
  const refs = [...store.localBranches.map((ref) => ({ name: ref.name, icon: <GitBranch size={13}/> })), ...store.remoteBranches.map((ref) => ({ name: ref.name, icon: <Cloud size={13}/> })), ...store.tags.map((ref) => ({ name: ref.name, icon: <Tag size={13}/> }))];
  // folders drop from the start when the bar is short of room; the file name is never cut (docs/design.md, Text)
  const pathFolders = (selected ? selected.path.split("/").slice(0, -1) : directory.split("/")).filter(Boolean), fileName = selected?.path.split("/").at(-1) ?? "";
  const dropped = droppedFolders(pathFolders, fileName, Math.floor(pathWidth / 7.5));
  // one grammar for every view: what is shown on the left; the language, the lines and "Read only" on the right
  const historyEntry = history?.find((entry) => entry.commit.id === historySelected) ?? history?.[0];
  const shownHash = mode === "History" ? historyEntry?.commit.id.slice(0, 7) ?? "" : hash;
  // a first commit has no parent to compare with
  const shown = mode === "History" ? (historyEntry ? t(historyEntry.commit.parents.length ? "Changes in {0} against its parent" : "As of commit {0}", shownHash) : "")
    : mode === "Blame" ? t("Blame of the revision shown · uncommitted changes not shown") : mode === "Working changes" ? t("Uncommitted changes against HEAD") : hash ? t("As of commit {0}", hash) : "";
  const shownParts = shownHash && shown.includes(shownHash) ? [shown.slice(0, shown.indexOf(shownHash)), shown.slice(shown.indexOf(shownHash) + shownHash.length)] : null;
  const shownLines = mode === "Source" || mode === "Preview" ? (blob?.text ? lineCount : null) : lines;
  const image = !!blob?.image && mode === "Source";
  const languageName = selectedLanguage === "Other files" ? t("Plain text") : ["Plain text", "Configuration"].includes(selectedLanguage) ? t(selectedLanguage) : selectedLanguage;
  const facts = [image ? formatRepositoryBytes(selected?.size ?? 0) : languageName, ...(!image && shownLines != null ? [t("{0} lines", shownLines.toLocaleString())] : []), t("Read only")];
  return <section ref={section} className="repository-code" onKeyDown={(event) => { if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f" && !quickOpen && reading) { event.preventDefault(); findInput.current?.focus(); findInput.current?.select(); } }}>
    <header className="code-bar" role="toolbar" aria-label={t("Code")}>
      <div className="code-revision" ref={revisionHost}>
        <button type="button" className="code-bar-button" aria-haspopup="dialog" aria-expanded={revisionPicker} aria-label={`${t("Revision")} ${hash || input}${name ? `, ${name}` : ""}`} data-tip={t("Choose a branch or tag")} onClick={() => { setRevisionSearch(""); setRevisionPicker((value) => !value); }}>
          <GitCommitHorizontal size={13}/>{loading ? <Spinner size={12}/> : tree ? <><code>{hash}</code>{name && <><span className="code-bar-dot" aria-hidden>·</span><span className="ellipsis">{name}</span></>}</> : <span className="ellipsis">{input}</span>}<ChevronDown size={10}/>
        </button>
        {/* any revision can be typed; the branches and tags below narrow as it is typed */}
        {revisionPicker && <div className="code-revision-list" role="dialog" aria-label={t("Revision")}>
          <form onSubmit={(event) => { event.preventDefault(); if (validRevisionInput(typed)) void load(typed); }}>
            <input className="input" autoFocus aria-label={t("Revision")} placeholder={t("Revision")} value={revisionSearch} onChange={(event) => setRevisionSearch(event.target.value)}/>
            <Button type="submit" disabled={loading || !validRevisionInput(typed)}>{t("Load revision")}</Button>
          </form>
          <div className="code-revision-refs">{refs.filter((ref) => !typed || ref.name.toLowerCase().includes(typed.toLowerCase())).map((ref, index) => <button type="button" key={index} className={`code-file-row ${ref.name === input ? "on" : ""}`} onClick={() => void load(ref.name)}>{ref.icon}<span>{ref.name}</span></button>)}</div>
        </div>}
      </div>
      <span className="code-bar-sep" aria-hidden/>
      <div className="code-history-controls">
        <button type="button" className="code-bar-button icon" aria-label={t("Navigate back")} data-tip={t("Navigate back")} disabled={navigation.cursor <= 0} onClick={() => navigate(-1)}><ChevronLeft size={14}/></button>
        <button type="button" className="code-bar-button icon" aria-label={t("Navigate forward")} data-tip={t("Navigate forward")} disabled={navigation.cursor >= navigation.history.length - 1} onClick={() => navigate(1)}><ChevronRight size={14}/></button>
      </div>
      <span className="code-bar-sep" aria-hidden/>
      <nav className="code-path" ref={pathBar} aria-label={t("File path")}>
        {dropped > 0 && <span className="code-path-sep">…</span>}
        {pathFolders.map((folder, index) => index < dropped ? null : <span key={index}>{(index > 0) && <span className="code-path-sep" aria-hidden>›</span>}<button type="button" onClick={() => { setDirectory(pathFolders.slice(0, index + 1).join("/")); setLanguageFilter(null); }}>{folder}</button></span>)}
        {fileName && <>{pathFolders.length > 0 && <span className="code-path-sep" aria-hidden>›</span>}<strong aria-current="page">{fileName}</strong></>}
      </nav>
      {/* opens the quick-open palette; drawn as the field it leads to */}
      <button type="button" className="code-quick-field" aria-label={t("Quick open")} aria-keyshortcuts="Control+P" disabled={!tree} onClick={() => setQuickOpen(true)}><Search size={13}/><span>{t("Quick open")}</span><kbd>{keyLabel("Ctrl+P")}</kbd></button>
      {/* the board has no place for these two; they stay at the end of the bar */}
      {repo && <CodeExternalEditors repo={repo} file={selected?.kind === "file" ? selected.path : null} source={editorSource}/>}
      <IconButton tip={t(explorer ? "Hide file explorer" : "Show file explorer")} aria-label={t(explorer ? "Hide file explorer" : "Show file explorer")} aria-pressed={explorer} onClick={() => setExplorer((value) => !value)} icon={explorer ? <PanelLeftClose size={16}/> : <PanelLeftOpen size={16}/>} />
    </header>
    {error && <div role="alert" className="code-notice error-text">{error}</div>}
    {tree?.truncated && <div className="code-notice hint">{t("File list truncated. Narrow the repository or use another tool for the remaining files.")}</div>}
    <div className={`code-reader-layout ${explorer ? "" : "focused"}`}>
      {explorer && <nav className="code-explorer" aria-label={t("Repository files")}>
        <div className="code-file-list">{directory && <button type="button" className="code-file-row folder parent" aria-label={t("Parent folder")} title={t("Parent folder")} onClick={() => setDirectory(directory.split("/").slice(0, -1).join("/"))}><CornerLeftUp size={13}/><code>..</code></button>}
          {folders.map((folder) => <button type="button" className="code-file-row folder" key={folder} onClick={() => setDirectory(folder)}><Folder size={13}/><span>{folder.slice(prefix.length)}</span></button>)}
          {entries.slice(0, 2000).map((entry) => <button type="button" key={entry.path} className={`code-file-row ${selected?.path === entry.path ? "on" : ""}`} aria-current={selected?.path === entry.path ? "true" : undefined} onClick={() => { if (tree) void readFile(entry, tree); }} title={entry.path}><File size={13}/><span>{entry.path.slice(prefix.length)}</span>{entry.kind !== "file" && <span className="code-entry-kind">{entry.kind === "symlink" ? "↪" : "⊞"}</span>}{changed.has(entry.path) && <StatusBadge kind={changed.get(entry.path)!}/>}</button>)}
          {entries.length > 2000 && <p className="hint">{t("Showing the first 2,000 matches. Search to narrow the file list.")}</p>}{tree && !entries.length && !folders.length && <Empty title={t("No matching files")}/>}
        </div>
        {tree && <RepositoryLanguages summary={languageSummary} selected={languageFilter} select={(value) => { setLanguageFilter(value); setDirectory(""); }}/>}
      </nav>}
      <main className="code-document">
        {/* one open file needs no tab of its own */}
        {navigation.tabs.length > 1 && <div className="code-open-files" aria-label={t("Open files")}><div className="code-file-tabs">{navigation.tabs.map((tab) => <div className={`code-file-tab ${selected?.path === tab.path ? "on" : ""}`} key={tab.path}><button type="button" title={tab.path} aria-current={selected?.path === tab.path ? "page" : undefined} onClick={() => { const entry = allEntries.find((item) => item.path === tab.path); if (entry && tree) void readFile(entry, tree, tab.mode); }}><span>{tab.path.split("/").at(-1)}</span></button><button type="button" className="code-close-file" aria-label={t("Close file")} data-tip={t("Close file")} onClick={() => closeFile(tab.path)}><X size={12}/></button></div>)}</div><IconButton small icon={<X size={13}/>} aria-label={t("Close all files")} tip={t("Close all files")} onClick={() => { updateNavigation({ ...navigationState.current, tabs: [] }); clearSelection(); }}/></div>}
        {selected ? <>
          {/* Source, History with its count, Blame and Working changes: underline tabs, so a label never shifts */}
          <nav className="code-view-tabs" aria-label={t("Source")}>{(canPreview ? ["Source", "Preview", ...modes.slice(1)] as CodeViewMode[] : modes).map((view) => <button type="button" key={view} data-view={view} aria-current={mode === view ? "page" : undefined} className={mode === view ? "on" : ""} disabled={selected.kind !== "file" && view !== "Source"} onClick={() => { if (tree) void readFile(selected, tree, view); }}>{t(view)}{view === "History" && !!history?.length && <StatusPill tone="neutral">{historyCountLabel(history.length)}</StatusPill>}</button>)}</nav>
          {reading && <div className="code-reading-tools"><label className="code-search code-find"><Search size={14}/><input ref={findInput} aria-label={t("Find in file")} placeholder={t("Find in file")} value={find} disabled={fileLoading} onChange={(event) => { setFind(event.target.value); setActiveMatch(0); }} onKeyDown={(event) => { if (event.key === "Enter") moveMatch(event.shiftKey ? -1 : 1); if (event.key === "Escape") setFind(""); }}/>{find && <span className="code-match-count" role="status">{matches.length ? t("{0} of {1}", matchIndex + 1, matches.length === sourceMatchLimit ? `${sourceMatchLimit.toLocaleString()}+` : matches.length) : t("No matches")}</span>}</label>
            <div className="code-tool-group"><IconButton small icon={<ArrowUp size={14}/>} aria-label={t("Previous match")} tip={t("Previous match")} disabled={!matches.length} onClick={() => moveMatch(-1)}/><IconButton small icon={<ArrowDown size={14}/>} aria-label={t("Next match")} tip={t("Next match")} disabled={!matches.length} onClick={() => moveMatch(1)}/></div>
            <CodePositionTools lineCount={lineCount} symbols={symbols} enabled={!fileLoading} focusRequest={lineFocus} jump={(line) => setLineJump((value) => ({ line, id: (value?.id ?? 0) + 1 }))}/>
            <div className="code-tool-group code-display-tools"><IconButton small icon={<WrapText size={15}/>} aria-label={t("Wrap lines")} aria-pressed={wrap} tip={t(lineCount > wrappingLineLimit ? "Wrapping is unavailable for files with more than 5,000 lines." : "Wrap lines")} disabled={lineCount > wrappingLineLimit} className={wrap ? "on" : ""} onClick={() => setWrap((value) => !value)}/><IconButton small icon={<span className="code-font-adjust">A−</span>} aria-label={t("Decrease font size")} tip={t("Decrease font size")} disabled={fontSize <= 11} onClick={() => setFontSize((value) => Math.max(11, value - 1))}/><IconButton small icon={<CaseSensitive size={18}/>} aria-label={t("Increase font size")} tip={t("Increase font size")} disabled={fontSize >= 20} onClick={() => setFontSize((value) => Math.min(20, value + 1))}/><IconButton small icon={copied ? <Check size={14}/> : <Copy size={14}/>} aria-label={t(copied ? "Copied" : "Copy source")} tip={t(copied ? "Copied" : "Copy source")} disabled={!text || fileLoading} onClick={() => void copy()}/></div>
          </div>}
          {blob?.notice && <p className="code-notice hint">{blob.notice}</p>}
          {fileLoading ? <div className="code-loading" role="status"><Spinner/>{t("Loading…")}</div>
            : mode === "History" && repo ? <CodeHistoryView store={store} repo={repo} entries={history} local={local} selected={historySelected} select={setHistorySelected} read={source.read} wrap={wrap} setWrap={setWrap} onLines={setLines}/>
            : mode === "Working changes" && repo ? <CodeChangesView store={store} repo={repo} path={selected.path} commit={null} read={source.read} wrap={wrap} setWrap={setWrap} onLines={setLines}/>
            : mode === "Blame" && blame?.length ? <CodeBlameView lines={blame} wrap={wrap} show={(commit) => store.reveal(commit)} before={before}/>
            : image ? <div className="code-image"><img src={blob!.image} alt={selected.path}/></div>
            : mode === "Preview" && tree && text ? /\.html?$/i.test(selected.path) ? <RepositoryHTMLPreview text={text} path={selected.path} revision={tree.revision} entries={allEntries} read={previewReader}/> : <div className="code-markdown-preview"><Markdown text={text} canLoadImage={() => false}/></div>
            : mode === "Source" && text ? <RepositorySourceView text={text} language={language} fontSize={fontSize} wrap={wrap} matches={matches} activeMatch={matchIndex} lineCount={lineCount} jump={lineJump}/>
            : <div className="code-empty-content hint">{blob?.notice ? "" : t("No content to show.")}</div>}
          <footer className="code-status-bar"><span className="ellipsis">{shownParts ? <>{shownParts[0]}<code>{shownHash}</code>{shownParts[1]}</> : shown}</span><span className="spacer"/><span title={formatRepositoryBytes(selected.size)}>{facts.join(" · ")}</span></footer>
        </> : <div className="code-empty-content">{loading ? <Spinner/> : <Empty title={t("Choose a file")} detail={t("Search paths or choose a file from the repository tree.")}/>}</div>}
      </main>
    </div>
    {quickOpen && tree && <CodeQuickOpen entries={allEntries} recent={navigation.recent} close={() => setQuickOpen(false)} open={(entry) => void readFile(entry, tree)}/>}
  </section>;
}
