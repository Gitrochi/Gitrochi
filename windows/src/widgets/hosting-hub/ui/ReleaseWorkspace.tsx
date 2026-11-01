import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, ArrowRight, Download, ExternalLink, GitCompare, MoreHorizontal, Pencil, Plus, RefreshCw, Search, Tag, ArrowDownWideNarrow } from "lucide-react";
import { accounts, HostingHubStore, deleteHubItem, hubSafeURL, orderedReleases, newestReleases, defaultReleaseFamily, releasePackageName, releaseAssetGroups, releaseTag, releaseDate, releaseState, releaseFamily, releaseCompareURL, releaseAssetSize, saveHubRelease, type HubSource, type HubItem, type HubReleaseInput, type HubAccess, type HubDetail } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, IconButton, Spinner, HostingDate } from "@/shared/ui";
import { ProjectReviewDialog } from "./ProjectReviewDialog";
import { ReleaseMarkdown } from "./ReleaseMarkdown";
import { ReleaseSummary } from "./ReleaseSummary";
import "./releases.css";

type Review = { title: string; body: string; stamp: string; action: (access: HubAccess) => Promise<void> };
type Asset = HubDetail["assets"][number];
const blank = (github: boolean): HubReleaseInput => ({ tag: "", name: "", body: "", target: "", draft: github, prerelease: false });
const stateHelp: Record<string, string> = { Stable: "Published releases", Prerelease: "Published, but marked as not ready for production", Draft: "Saved but not published; only people with write access see it" };
export function ReleaseWorkspace({ source }: { source: HubSource }) {
  const hub = useMemo(() => "hostingHub" in source && source.hostingHub instanceof HostingHubStore ? source.hostingHub : new HostingHubStore(source), [source]);
  useObserve(hub); useObserve(accounts);
  const stamp = hub.contextStamp;
  const [editor, setEditor] = useState<"new" | "edit" | null>(null), [input, setInput] = useState(blank(true));
  const [preview, setPreview] = useState(false), [review, setReview] = useState<Review | null>(null);
  const [filter, setFilter] = useState("All releases"), [sort, setSort] = useState<"date" | "version">("date"), [family, setFamily] = useState<string | null>(null);
  const [detailOpen, setDetailOpen] = useState(false), [base, setBase] = useState("");
  const textarea = useRef<HTMLTextAreaElement>(null), selection = useRef<[number, number]>([0, 0]);
  const heading = useRef<HTMLHeadingElement>(null), listFocus = useRef<HTMLButtonElement>(null);
  useLayoutEffect(() => { setEditor(null); setReview(null); setDetailOpen(false); setFamily(null); setFilter("All releases"); setBase(""); void hub.activate("releases"); }, [hub, stamp]);
  useLayoutEffect(() => () => hub.reset(), [hub]);
  const busy = hub.loading || hub.busy || hub.detailLoading;
  const detail = hub.detail;
  // One package at a time: "latest" and the timeline mean nothing across separately versioned products.
  const families = [...new Set(hub.items.map(releaseFamily))].sort();
  const current = family ?? defaultReleaseFamily(hub.items);
  const packaged = hub.items.filter(item => releaseFamily(item) === current);
  const states = new Set(packaged.map(releaseState)), mixed = [...states].some(state => state !== "Stable");
  const shown = mixed ? filter : "All releases";
  const items = orderedReleases(hub.filteredItems.filter(item => releaseFamily(item) === current && (shown === "All releases" || releaseState(item) === shown)), sort);
  const latest = newestReleases(packaged).stable;
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
  const comparable = detail && releaseState(detail.item) !== "Draft" ? orderedReleases(hub.items.filter(item => releaseState(item) !== "Draft" && releaseCompareURL(source.target, releaseTag(item), tag))) : [];
  // Preselect the release before this one, preferring the same state (a stable compares with the previous stable).
  const older = comparable.filter(item => detail && releaseDate(item) < releaseDate(detail.item));
  const fallback = older.find(item => detail && releaseState(item) === releaseState(detail.item)) ?? older[0] ?? comparable[0];
  const from = base || (fallback ? releaseTag(fallback) : "");
  const comparison = releaseCompareURL(source.target, from, tag);
  const groups = detail ? releaseAssetGroups(detail.assets, tag) : { primary: [], other: [] };
  const target = detail ? String(detail.item.data.target_commitish ?? "") : "";
  const asset = (value: Asset) => <div className="release-asset" key={value.id}><div className="grow"><strong title={value.name}>{value.name}</strong><div className="hint">{value.size !== undefined && releaseAssetSize(value.size)}{value.downloads !== undefined && ` · ${value.downloads.toLocaleString()} ${t("downloads")}`}{!hubSafeURL(urlContext, value.url, true) && <span className="release-asset-blocked">{t("External download blocked; inspect the release page.")}</span>}</div></div>{hubSafeURL(urlContext, value.url, true) && <IconButton small icon={<Download size={14}/>} aria-label={t("Download in browser")} tip={t("Download in browser")} onClick={() => open(value.url, true)}/>}</div>;
  return <section className={`hosting-hub release-workspace ${detailOpen ? "release-detail-open" : ""}`} aria-label={t("Releases")}>
    <header className="release-toolbar"><span className="hint release-location">{source.target ? `${source.target.host} / ${source.target.path}` : t("Open a repository to view releases.")}</span>
      {families.length > 1 && <label className="release-package"><span>{t("Package")}</span><select aria-label={t("Package")} value={current} disabled={busy} onChange={e => { setFamily(e.target.value); setFilter("All releases"); setDetailOpen(false); }}>{families.map(value => <option key={value} value={value}>{releasePackageName(hub.items, value) || t("Repository releases")}</option>)}</select></label>}
      <span className="grow"/>
      <Button disabled={busy || !!editor} tip={t("Refresh")} aria-label={t("Refresh")} onClick={() => { setDetailOpen(false); void hub.load(); }}><RefreshCw size={14}/></Button>
      <Button kind="primary" disabled={busy || !hub.account} onClick={() => edit(false)}><Plus size={14}/>{t("New release")}</Button>
    </header>
    {!hub.error && <ReleaseSummary source={source} items={packaged} family={current}/>}
    {hub.notice && <div className="hub-notice" role="status">{hub.notice}</div>}
    {hub.error && <div className="hub-notice hub-error" role="alert"><p>{hub.error}</p><Button disabled={busy} onClick={() => void (detail ? hub.select(detail.item) : hub.load())}>{t("Retry")}</Button></div>}
    <div className="hub-split"><aside className="hub-list">
      <div className="release-list-tools"><label className="release-search"><Search size={14}/><input aria-label={t("Search loaded items")} placeholder={t("Search loaded items")} value={hub.query} onChange={e => hub.setQuery(e.target.value)}/></label><label className="release-sort" data-tip={t("Sort releases")}><ArrowDownWideNarrow size={14}/><select aria-label={t("Sort releases")} value={sort} onChange={e => setSort(e.target.value as "date" | "version")}><option value="date">{t("Newest first")}</option><option value="version">{t("Version number")}</option></select></label></div>
      {mixed && <div className="release-states" role="group" aria-label={t("Release status")}>{(["All releases", "Stable", "Prerelease", "Draft"] as const).filter(state => state === "All releases" || states.has(state)).map(state => <button key={state} type="button" aria-pressed={shown === state} data-tip={stateHelp[state] && t(stateHelp[state])} onClick={() => setFilter(state)}>{t(state === "All releases" ? "All" : state)}<span>{(state === "All releases" ? packaged : packaged.filter(item => releaseState(item) === state)).length}</span></button>)}</div>}
      {sort === "version" && <p className="hint">{t("Version ordering applies to one SemVer package; other selections use published dates.")}</p>}
      {items.map((item, index) => <button ref={index === 0 ? listFocus : undefined} key={item.id} className={`hub-item ${detail?.item.id === item.id && !editor ? "active" : ""}`} aria-pressed={detail?.item.id === item.id && !editor} disabled={hub.busy} onClick={() => select(item)}><span className="release-row-top"><strong>{releaseTag(item)}</strong><ReleaseBadge item={item}/>{item.id === latest?.id && <LatestBadge/>}<span className="release-row-date">{releaseState(item) === "Draft" ? <span className="hosting-date">{t("Not published")}</span> : <HostingDate value={releaseDate(item)}/>}</span></span><span>{item.title}</span></button>)}
      {!hub.loading && !items.length && !hub.error && <p className="hint">{t(hub.items.length ? "No matching releases." : "No releases found for this repository.")}</p>}
      {hub.loading ? <Spinner/> : hub.more && <div className="release-more"><Button disabled={busy} onClick={() => void hub.load(true)}>{t("Load more")}</Button><p className="hint">{t("Search filters loaded pages. Load more to search older items.")}</p></div>}
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
        <div className="release-title"><span className="release-tag">{tag}</span><ReleaseBadge item={detail.item}/>{detail.item.id === latest?.id && <LatestBadge/>}
          <div className="release-title-actions">{hubSafeURL(urlContext, detail.item.url) && <Button size="small" onClick={() => open(detail.item.url)}><ExternalLink size={14}/>{t("Open in browser")}</Button>}<Button size="small" disabled={busy} onClick={() => edit(true)}><Pencil size={14}/>{t("Edit")}</Button><details className="release-menu"><summary aria-label={t("Release actions")} data-tip={t("Release actions")}><MoreHorizontal size={16}/></summary><Button disabled={busy} onClick={() => setReview({ title: t("Delete this item?"), body: `${detail.item.title}\n${t("This removes the remote item. Release tags and git history are kept.")}`, stamp: hub.actionStamp, action: async c => { await deleteHubItem(c, detail.item); setDetailOpen(false); } })}>{t("Delete")}</Button></details></div>
        </div>
        <h2 ref={heading} tabIndex={-1}>{detail.item.title}</h2>
        <div className="release-detail-meta">{releaseState(detail.item) === "Draft" ? <span>{t("Not published")}</span> : <HostingDate value={releaseDate(detail.item)} published/>}{target && <><span className="release-meta-dot">·</span><span>{t("Tagged from {0}", target)}</span></>}{detail.assets.length > 0 && <><span className="release-meta-dot">·</span><span>{t("Assets: {0}", detail.assets.length.toLocaleString())}</span></>}</div>
        <div className="release-body">
          <div className="release-notes">{detail.item.body ? <ReleaseMarkdown text={detail.item.body} target={source.target} tag={tag}/> : <p className="hint">{t("No release notes.")}</p>}</div>
          <aside className="release-side">
            <section className="release-card" aria-label={t("Release assets")}><h3>{t("Release assets")}</h3>{groups.primary.map(asset)}{groups.other.length > 0 && <details className="release-other-assets"><summary>{t("Other files ({0})", groups.other.length)}</summary>{groups.other.map(asset)}</details>}{!detail.assets.length && <p className="hint">{t("No release assets.")}</p>}</section>
            {comparable.length > 0 && <section className="release-card release-compare" aria-label={t("Compare changes")}><h3>{t("Compare changes")}</h3>
              <div className="release-compare-range"><select className="select" aria-label={t("Compare from")} value={from} onChange={e => setBase(e.target.value)}>{comparable.map(item => <option key={item.id} value={releaseTag(item)}>{releaseTag(item)}</option>)}</select><ArrowRight size={14}/><code title={tag}>{tag}</code><IconButton small icon={<ExternalLink size={14}/>} aria-label={t("Compare in browser")} tip={t("Compare in browser")} disabled={!comparison} onClick={() => comparison && open(comparison)}/></div>
              {source.showRevisionComparison && <Button size="small" className="release-compare-app" disabled={!from} onClick={() => source.showRevisionComparison?.(from, tag)}><GitCompare size={14}/>{t("Compare in app")}</Button>}
            </section>}
          </aside>
        </div>
      </article> : <div className="empty"><Tag size={28}/><p>{t("Select a release to read its notes and compare versions.")}</p></div>}
    </main></div>
  </section>;
}
// Stable is the norm, so only the exceptions get a badge.
function ReleaseBadge({ item }: { item: HubItem }) { const state = releaseState(item); return state === "Stable" ? null : <span className={`release-badge release-${state.toLowerCase()}`}>{t(state)}</span>; }
function LatestBadge() { return <span className="release-badge release-latest">{t("Latest")}</span>; }
