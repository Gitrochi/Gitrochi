import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowLeftRight, ArrowUpDown, ChevronDown, ChevronRight, Cloud, Folder, GitBranch, Search, Tag as TagIcon } from "@/shared/icons";
import { Equal, TriangleAlert } from "lucide-react";
import { commitCountLabel, comparisonCommitLimit, comparisonKey, comparisonReferences, defaultRebaseBase, type FileChange, fileDir, fileName, referenceMatches, StatusBadge, treeRows, validRevisionInput, type ComparisonReference } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { listWhen, useObserve } from "@/shared/lib";
import { git } from "@/shared/platform";
import { Button, Checkbox, FileViewToggle, HostedListEmpty, LineStatText, requestFileView, Spinner, StatusPill, useFileViewMode } from "@/shared/ui";
import { CodeChangesView } from "./CodeChangesView";
import { shortFolder } from "../lib/code-history";
import "./local-workbench.css";

type Read = (args: string[], repo: string) => Promise<string>;
const defaultRead: Read = async (args, repo) => (await git(args, repo)).stdout;
const ignoreLines = () => {};
const refIcon = (reference: ComparisonReference) => reference.kind === "remote" ? <Cloud size={13}/> : reference.kind === "tag" ? <TagIcon size={13}/> : <GitBranch size={13}/>;

/** From or To: the name chosen, and a popover where any revision can be typed or a branch or tag chosen */
function RevisionField({ title, value, resolved, references, onChoose }: { title: string; value: string; resolved: string | null; references: ComparisonReference[]; onChoose: (value: string) => void }) {
  const [open, setOpen] = useState(false), [typed, setTyped] = useState(""), host = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (event: Event) => { if (event instanceof KeyboardEvent ? event.key === "Escape" : !host.current?.contains(event.target as Node)) setOpen(false); };
    document.addEventListener("mousedown", close); document.addEventListener("keydown", close);
    return () => { document.removeEventListener("mousedown", close); document.removeEventListener("keydown", close); };
  }, [open]);
  const text = typed.trim(), choose = (next: string) => { onChoose(next); setOpen(false); };
  return <div className="compare-field" ref={host}>
    {/* the commit the name stood for when it was compared */}
    <button type="button" className="compare-picker" aria-haspopup="dialog" aria-expanded={open} aria-label={`${title}: ${value}`} data-tip={resolved ? `${value} · ${resolved.slice(0, 7)}` : undefined} onClick={() => { setTyped(""); setOpen((current) => !current); }}>
      <span className="compare-picker-label">{title}</span><span className="ellipsis">{value}</span><ChevronDown size={10}/>
    </button>
    {/* any revision can be typed; the branches and tags below narrow as it is typed */}
    {open && <div className="compare-revisions" role="dialog" aria-label={title}>
      <form onSubmit={(event) => { event.preventDefault(); if (validRevisionInput(text)) choose(text); }}>
        <input className="input" autoFocus aria-label={t("Branch, tag or commit")} placeholder={t("Branch, tag or commit")} value={typed} onChange={(event) => setTyped(event.target.value)}/>
        <Button type="submit" disabled={!validRevisionInput(text)}>{t("Apply")}</Button>
      </form>
      <div className="compare-revision-refs">{references.filter((reference) => referenceMatches(reference.name, text)).map((reference) =>
        <button type="button" key={reference.kind + ":" + reference.name} className={`compare-ref${reference.name === value ? " on" : ""}`} onClick={() => choose(reference.name)}>{refIcon(reference)}<span className="ellipsis">{reference.name}</span></button>)}</div>
    </div>}
  </div>;
}

/**
 * The Compare page, as the redesign's Compare board draws it: From and To in a 312px list column above the branches and
 * tags to compare with the current branch, and beside it Files and Commits tabs, the files as a tree next to the open
 * file's diff. The page compares as soon as either side changes. The "Compare revisions…" dialog keeps its own
 * one-column layout. (macOS: RevisionComparisonPanel)
 */
export function RevisionComparisonPanel({ store, read = defaultRead }: { store: RepoStore; read?: Read }) {
  useObserve(store);
  const mode = useFileViewMode(...requestFileView);
  const [tab, setTab] = useState<"files" | "commits">("files"), [filter, setFilter] = useState(""), [selected, setSelected] = useState<string | null>(null);
  const [collapsed, setCollapsed] = useState(new Set<string>()), [wrap, setWrap] = useState(false);
  const s = store.historyTools, result = s.comparison, head = store.headBranch ?? "HEAD";
  const change = () => store.changed();
  useEffect(() => () => store.cancelHistoryTools(), [store]);
  // on a first visit there is nothing to show yet: the usual base against the current branch, from where they split
  useEffect(() => {
    setSelected(null); setCollapsed(new Set()); setFilter("");
    const current = store.headBranch;
    if (s.comparison || s.comparisonLoading || s.left !== "HEAD~1" || s.right !== "HEAD" || !current) return;
    const names = [...store.localBranches, ...store.remoteBranches].map((branch) => branch.name);
    const base = defaultRebaseBase(names, current, store.status.upstream);
    if (base === current || !names.includes(base)) return;
    s.left = base; s.right = current; s.useMergeBase = true; change();
  }, [store.path]);
  // where every branch and tag points, so a side that moves compares again
  const targets = useMemo(() => {
    const map = new Map<string, string>();
    for (const ref of [...store.localBranches, ...store.remoteBranches, ...store.tags]) if (!map.has(ref.name)) map.set(ref.name, ref.target);
    return map;
  }, [store.localBranches, store.remoteBranches, store.tags]);
  // a dialog over the page owns the shared inputs while it is open; the page compares once it closes
  const key = comparisonKey(store.path ?? "", s.left, s.right, s.useMergeBase, store.headHash, targets) + (store.sheet ? "\0dialog" : "");
  useEffect(() => {
    if (store.sheet || !store.path || !validRevisionInput(s.left) || !validRevisionInput(s.right)) return;
    if (key === s.comparisonKey && (s.comparison || s.comparisonError || s.comparisonLoading)) return;
    // a swap or a quick second choice compares once
    const timer = setTimeout(() => { s.comparisonKey = key; void store.loadRevisionComparison(false); }, 120);
    return () => clearTimeout(timer);
  }, [key]);

  const local = store.localBranches.map((branch) => branch.name), remote = store.remoteBranches.map((branch) => branch.name), tags = store.tags.map((tag) => tag.name);
  const references = useMemo(() => comparisonReferences(local, remote, tags, store.headBranch), [local.join("\0"), remote.join("\0"), tags.join("\0"), store.headBranch]);
  const choices = useMemo(() => comparisonReferences(local, remote, tags, null), [local.join("\0"), remote.join("\0"), tags.join("\0")]);
  const rows = references.filter((reference) => referenceMatches(reference.name, filter));

  // "2 / 6", J and K follow the order the files are drawn in
  const files = useMemo(() => !result ? [] : mode !== "tree" ? result.files : treeRows(result.files, new Set()).flatMap((row) => (row.kind === "file" ? [row.change] : [])), [result, mode]);
  const open = files.find((file) => file.path === selected) ?? files[0] ?? null;
  const index = open ? files.indexOf(open) : -1;
  const step = (by: number) => { const next = files[index + by]; if (next) setSelected(next.path); };
  useEffect(() => {
    if (tab !== "files" || !files.length) return;
    const onKey = (event: KeyboardEvent) => {
      const element = event.target as HTMLElement | null;
      if (event.ctrlKey || event.metaKey || event.altKey || element?.closest?.("input, textarea, select, [contenteditable], .xterm") || document.querySelector(".modal-backdrop")) return;
      const key = event.key.toLowerCase();
      if (key === "j") { event.preventDefault(); step(1); } else if (key === "k") { event.preventDefault(); step(-1); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const fileRow = (file: FileChange, depth: number | null) => {
    const on = open?.path === file.path, stat = result?.stats[file.path];
    return <button type="button" key={file.path} className={`compare-file${on ? " on" : ""}`} aria-current={on || undefined} style={{ paddingLeft: depth == null ? 6 : 24 + depth * 14 }} data-tip={file.oldPath ? `${file.oldPath} → ${file.path}` : file.path} onClick={() => setSelected(file.path)}>
      <StatusBadge kind={file.kind}/>
      {/* a rename's old name gives way first; the file name is never cut */}
      {file.oldPath && file.oldPath !== file.path && <span className="compare-file-from">{fileName(file.oldPath)} →</span>}
      <span className="compare-file-name">{fileName(file.path)}</span>
      {depth == null && <span className="compare-file-from" title={fileDir(file.path)}>{shortFolder(fileDir(file.path))}</span>}
      <span className="spacer"/>
      {stat && <LineStatText added={stat.added ?? 0} deleted={stat.deleted ?? 0}/>}
    </button>;
  };

  const filesView = () => !result ? null : !result.files.length
    ? <HostedListEmpty icon={<Equal size={24}/>} title={t("No differences between these revisions.")}/>
    : <div className="compare-files">
      <section className="compare-tree" aria-label={t("Changed files")}>
        <div className="compare-tree-head"><strong>{t("Changed files")}</strong><FileViewToggle view={requestFileView}/></div>
        <div className="compare-tree-rows" role="group">
          {mode === "tree" ? treeRows(result.files, collapsed).map((row) => row.kind === "folder"
            ? <button type="button" key={row.id} className="compare-folder" aria-expanded={!collapsed.has(row.path)} style={{ paddingLeft: 6 + row.depth * 14 }} onClick={() => setCollapsed((value) => { const next = new Set(value); if (!next.delete(row.path)) next.add(row.path); return next; })}>
              {collapsed.has(row.path) ? <ChevronRight size={12}/> : <ChevronDown size={12}/>}<Folder size={13}/><span className="ellipsis">{row.name}</span>
              {/* a folder holding a single file needs no count */}
              {row.files.length > 1 && <StatusPill tone="neutral">{row.files.length}</StatusPill>}
            </button>
            : fileRow(row.change, row.depth))
            : result.files.map((file) => fileRow(file, null))}
        </div>
      </section>
      {open && store.path && <CodeChangesView store={store} repo={store.path} path={open.path} commit={result.right} base={result.base} oldPath={open.oldPath} position={{ index, count: files.length, step }} read={read} wrap={wrap} setWrap={setWrap} onLines={ignoreLines}/>}
    </div>;

  const commitsView = () => !result ? null : !result.commits.length
    ? <HostedListEmpty icon={<Equal size={24}/>} title={t("No commits between these revisions.")}/>
    : <div className="compare-commits" role="list" aria-label={t("Commits")}>
      {result.commits.slice(0, comparisonCommitLimit).map((commit) => <button type="button" role="listitem" key={commit.id} className="compare-commit" data-tip={t("Show commit")} onClick={() => store.reveal(commit.id)}>
        <code>{commit.id.slice(0, 7)}</code><span className="ellipsis compare-commit-subject">{commit.subject}</span><span className="compare-cap">{commit.author}</span>{commit.date != null && <span className="compare-cap">{listWhen(commit.date)}</span>}
      </button>)}
    </div>;

  return <section className="compare-page">
    <aside className="compare-column">
      <div className="compare-sides">
        <RevisionField title={t("From")} value={s.left} resolved={result?.left ?? null} references={choices} onChoose={(value) => { s.left = value; change(); }}/>
        <button type="button" className="btn compare-swap" aria-label={t("Swap From and To")} data-tip={t("Swap From and To")} onClick={() => { [s.left, s.right] = [s.right, s.left]; change(); }}><ArrowUpDown size={14}/></button>
        <RevisionField title={t("To")} value={s.right} resolved={result?.right ?? null} references={choices} onChoose={(value) => { s.right = value; change(); }}/>
      </div>
      <Checkbox checked={s.useMergeBase} onChange={(value) => { s.useMergeBase = value; change(); }} label={t("From the common ancestor")}/>
      <span className="compare-cap">{t("Updates as soon as either side changes. Uncommitted changes are excluded.")}</span>
      <div className="compare-rule" role="separator"/>
      <strong>{t("Compare with the current branch")}</strong>
      <label className="compare-search"><Search size={13}/><input aria-label={t("Filter branches and tags")} placeholder={t("Filter branches and tags")} value={filter} onChange={(event) => setFilter(event.target.value)}/></label>
      <div className="compare-refs" role="group" aria-label={t("Compare with the current branch")}>
        {rows.map((reference) => {
          const compared = s.left === reference.name && s.right === head;
          return <button type="button" key={reference.kind + ":" + reference.name} className={`compare-ref${compared ? " on" : ""}`} data-ref={reference.name} aria-current={compared || undefined} aria-label={compared ? t("{0}, compared now", reference.name) : t("Compare {0} with the current branch", reference.name)} onClick={() => { s.left = reference.name; s.right = head; change(); }}>
            {refIcon(reference)}<span className="ellipsis">{reference.name}</span><span className="compare-ref-go" aria-hidden>{t("Compare")}</span>
          </button>;
        })}
        {!rows.length && <p className="compare-cap">{t("No matching branches")}</p>}
      </div>
    </aside>
    <main className="compare-main">
      <div className="compare-tabs">
        <div role="tablist" className="compare-tablist">
          <button type="button" role="tab" aria-selected={tab === "files"} className={`compare-tab${tab === "files" ? " on" : ""}`} onClick={() => setTab("files")}>{t("Files")}{result && <StatusPill tone="neutral">{result.files.length}</StatusPill>}</button>
          <button type="button" role="tab" aria-selected={tab === "commits"} className={`compare-tab${tab === "commits" ? " on" : ""}`} onClick={() => setTab("commits")}>{t("Commits")}{result && <StatusPill tone="neutral">{commitCountLabel(result.commits.length)}</StatusPill>}</button>
        </div>
        <span className="spacer"/>
        {s.comparisonLoading && result && <span role="status" aria-label={t("Comparing…")}><Spinner size={12}/></span>}
        {result?.mergeBase && <span className="compare-cap">{t("Common ancestor")} <code>{result.base.slice(0, 7)}</code></span>}
      </div>
      <div className="compare-body">
        {s.comparisonError
          ? <HostedListEmpty failed icon={<TriangleAlert size={24}/>} title={t("Couldn't compare these revisions")} caption={s.comparisonError} action={{ label: t("Retry"), onClick: () => { s.comparisonKey = ""; void store.loadRevisionComparison(false); } }}/>
          : result ? tab === "files" ? filesView() : commitsView()
          : s.comparisonLoading ? <div className="compare-loading" role="status"><Spinner/></div>
          : <HostedListEmpty icon={<ArrowLeftRight size={24}/>} title={t("Choose two revisions to compare")} caption={t("Use branches, tags or commit IDs, or pick a branch on the left.")}/>}
      </div>
    </main>
  </section>;
}
