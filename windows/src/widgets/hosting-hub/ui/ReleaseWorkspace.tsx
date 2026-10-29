import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, Download, ExternalLink, MoreHorizontal, Plus, RefreshCw, Tag, GitBranch, Sparkles, ArrowDownWideNarrow } from "lucide-react";
import { accounts, HostingHubStore, deleteHubItem, hubSafeURL, orderedReleases, newestReleases, releaseTag, releaseDate, releaseState, releaseFamily, releaseCompareURL, releaseAssetSize, saveHubRelease, type HubSource, type HubItem, type HubReleaseInput, type HubAccess } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { git } from "@/shared/platform";
import { Button, Spinner, HostingDate } from "@/shared/ui";
import { ProjectReviewDialog } from "./ProjectReviewDialog";
import { ReleaseMarkdown } from "./ReleaseMarkdown";
import "./releases.css";

type Review = { title: string; body: string; stamp: string; action: (access: HubAccess) => Promise<void> };
const blank = (github: boolean): HubReleaseInput => ({ tag: "", name: "", body: "", target: "", draft: github, prerelease: false });
export function ReleaseWorkspace({ source }: { source: HubSource }) {
  const hub = useMemo(() => "hostingHub" in source && source.hostingHub instanceof HostingHubStore ? source.hostingHub : new HostingHubStore(source), [source]);
  useObserve(hub); useObserve(accounts);
  const stamp = hub.contextStamp;
  const [editor, setEditor] = useState<"new" | "edit" | null>(null), [input, setInput] = useState(blank(true));
  const [preview, setPreview] = useState(false), [review, setReview] = useState<Review | null>(null);
  const [filter, setFilter] = useState("All releases"), [sort, setSort] = useState<"date" | "version">("date"), [family, setFamily] = useState("*");
  const [detailOpen, setDetailOpen] = useState(false), [base, setBase] = useState("");
  const [nearest, setNearest] = useState<{ stamp: string; tag: string } | null>(null);
  const textarea = useRef<HTMLTextAreaElement>(null), selection = useRef<[number, number]>([0, 0]);
  const heading = useRef<HTMLHeadingElement>(null), listFocus = useRef<HTMLButtonElement>(null);
  useLayoutEffect(() => { setEditor(null); setReview(null); setDetailOpen(false); setFamily("*"); setFilter("All releases"); setBase(""); void hub.activate("releases"); }, [hub, stamp]);
  useLayoutEffect(() => () => hub.reset(), [hub]);
  useEffect(() => {
    let active = true;
    setNearest(null);
    if (source.path && source.headHash) void git(["describe", "--tags", "--abbrev=0", source.headHash], source.path, { ok: [0, 128] }).then(result => {
      if (active) setNearest({ stamp, tag: result.status === 0 ? result.stdout.trim() : "" });
    }).catch(() => { if (active) setNearest({ stamp, tag: "" }); });
    return () => { active = false; };
  }, [source.path, source.headHash, stamp]);
  const busy = hub.loading || hub.busy || hub.detailLoading;
  const detail = hub.detail;
  const families = [...new Set(hub.items.map(releaseFamily))];
  const scoped = hub.filteredItems.filter(item => family === "*" || releaseFamily(item) === family);
  const items = orderedReleases(scoped.filter(item => filter === "All releases" || releaseState(item) === filter), sort);
  const latest = newestReleases(hub.error || hub.loading ? [] : family === "*" ? hub.items : hub.items.filter(item => releaseFamily(item) === family));
  const sameFamily = new Set(hub.items.map(releaseFamily)).size <= 1;
  const exact = source.tags?.filter(tag => tag.target === source.headHash).map(tag => tag.name).join(", ");
  const urlContext = { target: { provider: hub.provider, host: source.target?.host ?? "" } };
  const open = (url: string, asset = false) => { const safe = hubSafeURL(urlContext, url, asset); if (safe) void ipc.openUrl(safe); };
  const select = (item: HubItem) => { setEditor(null); setReview(null); setBase(""); setDetailOpen(true); void hub.select(item).then(() => heading.current?.focus()); };
  const edit = (existing: boolean) => {
    const item = existing ? detail?.item : undefined;
    setInput(item ? { tag: releaseTag(item), name: item.title, body: item.body, target: String(item.data.target_commitish ?? ""), draft: item.data.draft === true, prerelease: item.data.prerelease === true } : blank(hub.provider === "github"));
    setEditor(existing ? "edit" : "new"); setPreview(false); setReview(null); setDetailOpen(true);
  };
  const changePreview = (value: boolean) => {
    if (value && textarea.current) selection.current = [textarea.current.selectionStart, textarea.current.selectionEnd];
    setPreview(value);
    if (!value) requestAnimationFrame(() => { textarea.current?.focus(); textarea.current?.setSelectionRange(...selection.current); });
  };
  const submit = () => {
    const payload = { ...input }, previous = editor === "edit" ? detail?.item : undefined;
    setReview({ title: payload.draft ? t("Save release draft?") : t("Publish release?"), body: `${source.target?.path ?? ""}\n${payload.tag} · ${payload.name}\n${payload.draft ? t("Only accounts with repository write access can see the draft.") : t("This publishes the release on the server.")}`, stamp: hub.actionStamp, action: async c => { await saveHubRelease(c, payload, previous); setEditor(null); setDetailOpen(false); } });
  };
  useEffect(() => { if (detailOpen && detail && !editor) heading.current?.focus(); }, [detailOpen, detail?.item.id, editor]);
  const tag = detail ? releaseTag(detail.item) : "";
  const comparison = releaseCompareURL(source.target, base, tag);
  const comparable = detail && releaseState(detail.item) !== "Draft" ? hub.items.filter(item => releaseState(item) !== "Draft" && releaseCompareURL(source.target, releaseTag(item), tag)) : [];
  return <section className={`hosting-hub release-workspace ${detailOpen ? "release-detail-open" : ""}`} aria-label={t("Releases")}>
    <header><div className="release-heading-icon"><Tag size={22}/></div><div className="grow"><strong>{t("Releases")}</strong><div className="hint">{source.target ? `${source.target.host} / ${source.target.path}` : t("Open a repository to view releases.")}</div></div><Button disabled={busy || !!editor} tip={t("Refresh")} aria-label={t("Refresh")} onClick={() => { setDetailOpen(false); void hub.load(); }}><RefreshCw size={14}/></Button><Button disabled={busy || !hub.account} onClick={() => edit(false)}><Plus size={14}/>{t("New")}</Button></header>
    <div className="release-versions" aria-label={t("Versions")}>
      <div className="release-version-primary"><span><Tag size={13}/>{t(hub.more ? "Newest loaded stable" : "Latest stable by date")}</span><strong>{sameFamily || family !== "*" ? latest.stable ? releaseTag(latest.stable) : "—" : t("Select a package")}</strong>{latest.stable && <HostingDate value={releaseDate(latest.stable)} published/>}</div>
      <div><span><GitBranch size={13}/>{t("Tag at checkout")}</span><strong>{exact || t("No tag at checkout")}</strong><small>{t("Local working copy")}</small></div>
      <div><span><GitBranch size={13}/>{t("Nearest ancestor tag")}</span><strong>{nearest?.stamp === stamp ? nearest.tag || t("No ancestor tag") : "—"}</strong><small>{t("From local Git history")}</small></div>
      <div><span><Sparkles size={13}/>{t(hub.more ? "Newest loaded prerelease" : "Latest prerelease by date")}</span><strong>{sameFamily || family !== "*" ? latest.prerelease ? releaseTag(latest.prerelease) : "—" : t("Select a package")}</strong><small>{t("Preview channel")}</small></div>
    </div>
    {hub.notice && <div className="hub-notice" role="status">{hub.notice}</div>}
    {hub.error && <div className="hub-notice hub-error" role="alert"><p>{hub.error}</p><Button disabled={busy} onClick={() => void (detail ? hub.select(detail.item) : hub.load())}>{t("Retry")}</Button></div>}
    <div className="hub-split"><aside className="hub-list">
      <input className="input" aria-label={t("Search loaded items")} placeholder={t("Search loaded items")} value={hub.query} onChange={e => hub.setQuery(e.target.value)}/>
      <div className="release-filters"><select className="select" aria-label={t("Release status")} value={filter} onChange={e => setFilter(e.target.value)}>{["All releases", "Stable", "Prerelease", "Draft"].filter(x => hub.provider === "github" || !["Draft", "Prerelease"].includes(x)).map(x => <option key={x} value={x}>{t(x)}</option>)}</select><span className="release-sort-icon"><ArrowDownWideNarrow size={14}/></span><select className="select" aria-label={t("Sort releases")} value={sort} onChange={e => setSort(e.target.value as "date" | "version")}><option value="date">{t("Newest first")}</option><option value="version">{t("Version number")}</option></select></div>
      {families.length > 1 && <select className="select" aria-label={t("Package")} value={family} onChange={e => setFamily(e.target.value)}><option value="*">{t("All packages")}</option>{families.map(x => <option key={x} value={x}>{x || t("Repository releases")}</option>)}</select>}
      <p className="hint">{t("Search filters loaded pages. Load more to search older items.")}</p>
      {sort === "version" && <p className="hint">{t("Version ordering applies to one SemVer package; other selections use published dates.")}</p>}
      {items.map((item, index) => <button ref={index === 0 ? listFocus : undefined} key={item.id} className={`hub-item ${detail?.item.id === item.id && !editor ? "active" : ""}`} aria-pressed={detail?.item.id === item.id && !editor} disabled={hub.busy} onClick={() => select(item)}><span className="release-row-top"><strong><Tag size={13}/> {releaseTag(item)}</strong><ReleaseBadge item={item}/></span><span>{item.title}</span><span className="release-row-date">{releaseState(item) === "Draft" ? <span className="hosting-date">{t("Not published")}</span> : <HostingDate value={releaseDate(item)}/>}</span></button>)}
      {!hub.loading && !items.length && !hub.error && <p className="hint">{t(hub.items.length ? "No matching releases." : "No releases found for this repository.")}</p>}
      {hub.loading ? <Spinner/> : hub.more && <Button disabled={busy} onClick={() => void hub.load(true)}>{t("Load more")}</Button>}
    </aside><main className="hub-content">
      <Button className="release-back" onClick={() => { setDetailOpen(false); setEditor(null); setReview(null); requestAnimationFrame(() => listFocus.current?.focus()); }}><ArrowLeft size={14}/>{t("Back to releases")}</Button>
      {review && <ProjectReviewDialog title={review.title} body={review.body} busy={hub.busy} error={hub.error} disabled={busy || hub.uncertainWrite || review.stamp !== hub.actionStamp} confirm={() => void hub.action(review.action, "list").then(ok => { if (ok || hub.uncertainWrite) setReview(null); if (hub.uncertainWrite) setEditor(null); })} cancel={() => setReview(null)}/>}
      {editor ? <div className="hub-form"><h3>{t(editor === "new" ? "New release" : "Edit release")}</h3>
        <label>{t("Tag")}<input className="input" disabled={busy || editor === "edit"} value={input.tag} onChange={e => setInput({ ...input, tag: e.target.value })}/></label>
        <label>{t("Name")}<input className="input" disabled={busy} value={input.name} onChange={e => setInput({ ...input, name: e.target.value })}/></label>
        <label>{t("Target branch or commit")}<input className="input" disabled={busy || editor === "edit" && hub.provider === "gitlab"} value={input.target} onChange={e => setInput({ ...input, target: e.target.value })}/></label>
        <div className="release-editor-tabs" role="group" aria-label={t("Release notes")}><Button aria-pressed={!preview} onClick={() => changePreview(false)}>{t("Write")}</Button><Button aria-pressed={preview} onClick={() => changePreview(true)}>{t("Preview")}</Button></div>
        <textarea ref={textarea} hidden={preview} aria-label={t("Release notes")} className="textarea" rows={14} disabled={busy} value={input.body} onChange={e => setInput({ ...input, body: e.target.value })}/>
        {preview && (input.body ? <ReleaseMarkdown text={input.body} target={source.target} tag={input.tag}/> : <p className="hint">{t("No release notes.")}</p>)}
        {hub.provider === "github" && <><label className="hub-check"><input type="checkbox" disabled={busy} checked={input.draft} onChange={e => setInput({ ...input, draft: e.target.checked })}/>{t("Draft")}</label><label className="hub-check"><input type="checkbox" disabled={busy} checked={input.prerelease} onChange={e => setInput({ ...input, prerelease: e.target.checked })}/>{t("Prerelease")}</label></>}
        <div className="hub-actions"><Button disabled={busy || !input.tag.trim() || !input.name.trim()} onClick={submit}>{t("Review and save")}</Button><Button disabled={hub.busy} onClick={() => { setEditor(null); setReview(null); }}>{t("Cancel")}</Button></div>
      </div> : hub.detailLoading && !detail ? <Spinner/> : detail ? <article className="release-article">
        <div className="release-title"><span className="release-tag">{tag}</span><ReleaseBadge item={detail.item}/></div><h2 ref={heading} tabIndex={-1}>{detail.item.title}</h2><div className="release-detail-meta">{releaseState(detail.item) === "Draft" ? <span>{t("Not published")}</span> : <HostingDate value={releaseDate(detail.item)} published/>}<span className="release-meta-dot">·</span><span>{t("Release notes")}</span></div>
        <div className="hub-actions">{hubSafeURL(urlContext, detail.item.url) && <Button onClick={() => open(detail.item.url)}><ExternalLink size={14}/>{t("Open in browser")}</Button>}<details className="release-menu"><summary aria-label={t("Release actions")}><MoreHorizontal size={16}/></summary><Button disabled={busy} onClick={() => edit(true)}>{t("Edit")}</Button><Button disabled={busy} onClick={() => setReview({ title: t("Delete this item?"), body: `${detail.item.title}\n${t("This removes the remote item. Release tags and git history are kept.")}`, stamp: hub.actionStamp, action: async c => { await deleteHubItem(c, detail.item); setDetailOpen(false); } })}>{t("Delete")}</Button></details></div>
        {comparable.length > 0 && <div className="release-compare"><label>{t("Compare from")}<select className="select" aria-label={t("Compare from")} value={base} onChange={e => setBase(e.target.value)}><option value="">{t("Choose a tag")}</option>{comparable.map(item => <option key={item.id} value={releaseTag(item)}>{releaseTag(item)}</option>)}</select></label><Button disabled={!comparison} onClick={() => comparison && open(comparison)}>{t("Compare changes")}</Button></div>}
        {detail.item.body ? <ReleaseMarkdown text={detail.item.body} target={source.target} tag={tag}/> : <p className="hint">{t("No release notes.")}</p>}
        <h3>{t("Release assets")}</h3>{detail.assets.map(asset => <div className="release-asset" key={asset.id}><Download size={16}/><div className="grow"><strong title={asset.name}>{asset.name}</strong><div className="hint">{asset.size !== undefined && releaseAssetSize(asset.size)}{asset.downloads !== undefined && ` · ${asset.downloads.toLocaleString()} ${t("downloads")}`}</div></div>{hubSafeURL(urlContext, asset.url, true) ? <Button size="small" onClick={() => open(asset.url, true)}>{t("Download in browser")}</Button> : <span className="hint">{t("External download blocked; inspect the release page.")}</span>}</div>)}{!detail.assets.length && <p className="hint">{t("No release assets.")}</p>}
      </article> : <div className="empty"><Tag size={28}/><p>{t("Select a release to read its notes and compare versions.")}</p></div>}
    </main></div>
  </section>;
}
function ReleaseBadge({ item }: { item: HubItem }) { const state = releaseState(item); return <span className={`release-badge release-${state.toLowerCase()}`}>{t(state)}</span>; }
