import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { ChevronDown, ChevronLeft, ChevronRight, CircleX, Download, ExternalLink, GitCompare, Globe, MoreHorizontal, Pencil, Plus, RefreshCw, Search, Tag } from "@/shared/icons";
import { accounts, HostingHubStore, deleteHubItem, hubSafeURL, orderedReleases, newestReleases, defaultReleaseFamily, releasePackageName, releaseAssetGroups, releaseTag, releaseDate, releaseState, releaseFamily, releaseCompareURL, releaseAssetSize, releaseTaggedOn, releaseToOpen, saveHubRelease, type HubSource, type HubItem, type HubReleaseInput, type HubAccess, type HubDetail } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { listWhen, useObserve } from "@/shared/lib";
import { Button, HostedAccountNeeded, HostedListChip, HostedListColumns, HostedListEmpty, HostedListHeader, HostedListIconButton, HostedListLoading, HostedListNotice, HostedListPage, HostedListRow, HostedListSearch, HostedListSegments, HostedListTextButton, type MenuItem, showContextMenu, showMenuBelow, Spinner, StatusPill } from "@/shared/ui";
import { ProjectReviewDialog } from "./ProjectReviewDialog";
import { ReleaseMarkdown } from "./ReleaseMarkdown";
import { ReleaseSummary } from "./ReleaseSummary";
import "./releases.css";

type Review = { title: string; body: string; stamp: string; action: (access: HubAccess) => Promise<void> };
type Asset = HubDetail["assets"][number];
const blank = (github: boolean): HubReleaseInput => ({ tag: "", name: "", body: "", target: "", draft: github, prerelease: false });
const stateHelp: Record<string, string> = { Prerelease: "Published, but marked as not ready for production", Draft: "Saved but not published; only people with write access see it" };

/**
 * Releases, as the redesign's Releases board draws it: where the page is and its actions, what this branch has not
 * released yet, then the list column and the open release beside it, with its notes, installers and comparison. The
 * page fills the window; only the list and side columns keep their widths. (macOS: ReleaseWorkspace.swift)
 */
export function ReleaseWorkspace({ source, openSettings }: { source: HubSource; openSettings?: () => void }) {
  const hub = useMemo(() => "hostingHub" in source && source.hostingHub instanceof HostingHubStore ? source.hostingHub : new HostingHubStore(source), [source]);
  useObserve(hub); useObserve(accounts);
  const stamp = hub.contextStamp;
  const [editor, setEditor] = useState<"new" | "edit" | null>(null), [input, setInput] = useState(blank(true));
  const [preview, setPreview] = useState(false), [review, setReview] = useState<Review | null>(null);
  const [filter, setFilter] = useState("All releases"), [sort, setSort] = useState<"date" | "version">("date"), [family, setFamily] = useState<string | null>(null);
  const [detailOpen, setDetailOpen] = useState(false), [base, setBase] = useState(""), [opened, setOpened] = useState<string | null>(null), [otherFiles, setOtherFiles] = useState(false);
  const textarea = useRef<HTMLTextAreaElement>(null), selection = useRef<[number, number]>([0, 0]);
  const heading = useRef<HTMLHeadingElement>(null);
  useLayoutEffect(() => { setEditor(null); setReview(null); setDetailOpen(false); setFamily(null); setFilter("All releases"); setBase(""); setOpened(null); void hub.activate("releases"); }, [hub, stamp]);
  useLayoutEffect(() => () => hub.reset(), [hub]);
  const busy = hub.loading || hub.busy || hub.detailLoading;
  const detail = hub.detail;
  // One package at a time: "latest" and the timeline mean nothing across separately versioned products.
  const families = [...new Set(hub.items.map(releaseFamily))].sort();
  const current = family ?? defaultReleaseFamily(hub.items);
  const packaged = hub.items.filter(item => releaseFamily(item) === current);
  const states = new Set(packaged.map(releaseState));
  // Drafts are the exception, so their segment appears only when there is one to show.
  const filters = ["All releases", "Stable", "Prerelease", ...(states.has("Draft") ? ["Draft"] : [])];
  const shown = filters.includes(filter) ? filter : "All releases";
  const inFilter = (item: HubItem) => releaseFamily(item) === current && (shown === "All releases" || releaseState(item) === shown);
  const items = orderedReleases(hub.filteredItems.filter(inFilter), sort);
  const latest = newestReleases(packaged).stable;
  const urlContext = { target: { provider: hub.provider, host: source.target?.host ?? "" } };
  const open = (url: string, asset = false) => { const safe = hubSafeURL(urlContext, url, asset); if (safe) void ipc.openUrl(safe); };
  const show = (item: HubItem) => { setBase(""); setOtherFiles(false); setOpened(item.id); return hub.select(item); };
  const select = (item: HubItem) => { setEditor(null); setReview(null); setDetailOpen(true); void show(item).then(() => heading.current?.focus()); };
  // An empty detail says nothing: open a release whenever the list has one and the open one is not in it. Search
  // leaves the open release alone, so that typing does not read a release for every key.
  const toOpen = editor || hub.loading || hub.detailLoading || hub.busy || hub.error || (detail && inFilter(detail.item)) ? undefined : items.find(item => item.id === opened) ?? releaseToOpen(items);
  useEffect(() => { if (toOpen) void show(toOpen); }, [toOpen?.id]);
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
  const remove = (item: HubItem) => setReview({ title: t("Delete this item?"), body: `${item.title}\n${t("This removes the remote item. Release tags and git history are kept.")}`, stamp: hub.actionStamp, action: async c => { await deleteHubItem(c, item); setDetailOpen(false); } });
  // The same actions on a selected row and behind the detail's more button; the others can only be opened or copied
  const menu = (item: HubItem, selected: boolean): MenuItem[] => [
    ...(hubSafeURL(urlContext, item.url) ? [{ label: t("Open in browser"), onClick: () => open(item.url) }, { label: t("Copy link"), onClick: () => void navigator.clipboard.writeText(item.url) }] : []),
    ...(selected ? [{ label: t("Edit"), disabled: busy, onClick: () => edit(true) }, "divider" as const, { label: t("Delete…"), danger: true, disabled: busy, onClick: () => remove(item) }] : []),
  ];
  const retry = () => void (detail ? hub.select(detail.item) : hub.load());
  useEffect(() => { if (detailOpen && detail && !editor) heading.current?.focus(); }, [detailOpen, detail?.item.id, editor]);
  const tag = detail ? releaseTag(detail.item) : "";
  const comparable = detail && releaseState(detail.item) !== "Draft" ? orderedReleases(hub.items.filter(item => releaseState(item) !== "Draft" && releaseCompareURL(source.target, releaseTag(item), tag))) : [];
  // Preselect the release before this one, preferring the same state (a stable compares with the previous stable).
  const older = comparable.filter(item => detail && releaseDate(item) < releaseDate(detail.item));
  const fallback = older.find(item => detail && releaseState(item) === releaseState(detail.item)) ?? older[0] ?? comparable[0];
  const from = base || (fallback ? releaseTag(fallback) : "");
  const comparison = releaseCompareURL(source.target, from, tag);
  const groups = detail ? releaseAssetGroups(detail.assets, tag) : { primary: [], other: [] };
  const tagged = detail && releaseTaggedOn(source.tags?.find(value => value.name === tag)?.target, String(detail.item.data.target_commitish ?? ""));
  const target = source.target;
  if (!target)
    return <HostedListPage className="release-workspace"><HostedListEmpty icon={<Globe size={24}/>} title={t("This repository has no GitHub or GitLab remote")} caption={t("Releases, pull requests and runs need a hosting remote.")}/></HostedListPage>;
  const settingsOpener = openSettings ?? (() => window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: "accounts" })));
  const query = hub.query.trim();
  const list = <aside className="hosted-list" aria-label={t("Release list")}>
    {families.length > 1 && <Button className="release-package" aria-label={t("Package")} tip={t("Package")} disabled={busy} onClick={event => showMenuBelow(event.currentTarget, families.map(value => ({ label: releasePackageName(hub.items, value) || t("Repository releases"), checked: value === current, onClick: () => { setFamily(value); setFilter("All releases"); setDetailOpen(false); } })))}><span className="ellipsis">{releasePackageName(hub.items, current) || t("Repository releases")}</span><ChevronDown size={12}/></Button>}
    <HostedListSearch prompt={t("Search releases")} text={hub.query} onText={text => hub.setQuery(text)} menuTitle={t("Sort")} menu={() => (["date", "version"] as const).map(value => ({ label: t(value === "date" ? "Newest first" : "Version number"), checked: sort === value, onClick: () => setSort(value) }))}/>
    <HostedListSegments<string> options={filters.map(state => ({ value: state, title: t(state === "All releases" ? "All" : state) }))} selection={shown} onSelect={setFilter}/>
    {sort === "version" && <p className="hosted-caption release-hint">{t("Version ordering applies to one SemVer package; other selections use published dates.")}</p>}
    {hub.error && !hub.items.length ? <HostedListEmpty failed icon={<CircleX size={24}/>} title={t("Couldn't reach {0}", target.host)} caption={hub.error} action={{ label: t("Retry"), onClick: retry }}/>
      : !hub.items.length && (hub.loading || hub.page === 0) ? <HostedListLoading caption={t("Loading releases…")}/>
      : !items.length ? (
        !hub.items.length ? <HostedListEmpty icon={<Tag size={24}/>} title={t("No releases yet")} caption={t("{0} has no releases.", target.path)}/>
          : query ? <HostedListEmpty icon={<Search size={24}/>} title={t("No releases match “{0}”", query)} action={{ label: t("Clear search"), onClick: () => hub.setQuery("") }}/>
          : <HostedListEmpty icon={<Tag size={24}/>} title={t("No matching releases.")} action={{ label: t("Show all releases"), onClick: () => setFilter("All releases") }}/>
      ) : <div className="hosted-rows">
        {items.map(item => { const selected = detail?.item.id === item.id && !editor; return <HostedListRow key={item.id} selected={selected} title={item.title} when={releaseWhen(item)} disabled={hub.busy} onClick={() => select(item)} onContextMenu={event => showContextMenu(event, menu(item, selected))}><span>{releaseTag(item)}</span><ReleaseMarkers item={item} latest={item.id === latest?.id}/></HostedListRow>; })}
        {hub.loading && <Spinner/>}
        {!hub.loading && hub.more && <div className="release-more"><HostedListTextButton className="hosted-more" disabled={busy} onClick={() => void hub.load(true)}>{t("Load more")}</HostedListTextButton><p className="hosted-caption">{t("Search filters loaded pages. Load more to search older items.")}</p></div>}
      </div>}
  </aside>;
  const asset = (value: Asset) => <div className="release-asset" key={value.id}><div className="grow"><strong title={value.name}>{value.name}</strong><div className="hosted-caption">{[value.size !== undefined && releaseAssetSize(value.size), value.downloads !== undefined && `${value.downloads.toLocaleString()} ${t("downloads")}`].filter(Boolean).join(" · ")}{!hubSafeURL(urlContext, value.url, true) && <span className="release-asset-blocked">{t("External download blocked; inspect the release page.")}</span>}</div></div>{hubSafeURL(urlContext, value.url, true) && <HostedListIconButton label={t("Download in browser")} onClick={() => open(value.url, true)}><Download size={14}/></HostedListIconButton>}</div>;
  const dialog = review && <ProjectReviewDialog title={review.title} body={review.body} busy={hub.busy} error={hub.error} disabled={busy || hub.uncertainWrite || review.stamp !== hub.actionStamp} confirm={() => void hub.action(review.action, "list").then(ok => { if (ok || hub.uncertainWrite) setReview(null); if (hub.uncertainWrite) setEditor(null); })} cancel={() => setReview(null)}/>;
  return <HostedListPage className="release-workspace" aria-label={t("Releases")}>
    <HostedListHeader host={target.host} path={target.path}>
      <HostedListIconButton label={t("Refresh")} disabled={busy || !!editor} onClick={() => { setDetailOpen(false); void hub.load(); }}><RefreshCw size={14}/></HostedListIconButton>
      <Button disabled={busy || !hub.account} onClick={() => edit(false)}><Plus size={13}/>{t("New release…")}</Button>
    </HostedListHeader>
    {!hub.account ? <HostedAccountNeeded gitlab={target.provider === "gitlab"} host={target.host} path={target.path} onConnect={settingsOpener}/> : <>
      <ReleaseSummary source={source} items={packaged} family={current}/>
      {hub.notice && <div className="hub-notice" role="status">{hub.notice}</div>}
      {hub.error && hub.items.length > 0 && <div className="release-notice"><HostedListNotice title={hub.error} retry={retry}/></div>}
      <HostedListColumns detail={detailOpen} list={list}>
        <div className="hosted-back"><Button onClick={() => { setDetailOpen(false); setEditor(null); setReview(null); }}><ChevronLeft size={14}/>{t("Back to releases")}</Button></div>
        {dialog}
        {editor ? <div className="hub-content release-form"><div className="hub-form"><h3>{t(editor === "new" ? "New release" : "Edit release")}</h3>
          <label>{t("Tag")}<input className="input" disabled={busy || editor === "edit"} value={input.tag} onChange={e => setInput({ ...input, tag: e.target.value })}/></label>
          <label>{t("Name")}<input className="input" disabled={busy} value={input.name} onChange={e => setInput({ ...input, name: e.target.value })}/></label>
          <label>{t("Target branch or commit")}<input className="input" disabled={busy || editor === "edit" && hub.provider === "gitlab"} value={input.target} onChange={e => setInput({ ...input, target: e.target.value })}/></label>
          <div className="release-editor-tabs" role="group" aria-label={t("Release notes")}><Button aria-pressed={!preview} onClick={() => changePreview(false)}>{t("Write")}</Button><Button aria-pressed={preview} onClick={() => changePreview(true)}>{t("Preview")}</Button></div>
          <textarea ref={textarea} hidden={preview} aria-label={t("Release notes")} className="textarea" rows={14} disabled={busy} value={input.body} onChange={e => setInput({ ...input, body: e.target.value })}/>
          {preview && (input.body ? <ReleaseMarkdown text={input.body} target={source.target} tag={input.tag}/> : <p className="hint">{t("No release notes.")}</p>)}
          {hub.provider === "github" && <><label className="hub-check"><input type="checkbox" disabled={busy} checked={input.draft} onChange={e => setInput({ ...input, draft: e.target.checked })}/>{t("Draft")}</label><label className="hub-check"><input type="checkbox" disabled={busy} checked={input.prerelease} onChange={e => setInput({ ...input, prerelease: e.target.checked })}/>{t("Prerelease")}</label></>}
          <div className="hub-actions"><Button kind="primary" disabled={busy || !input.tag.trim() || !input.name.trim()} onClick={submit}>{t("Review and save")}</Button><Button disabled={hub.busy} onClick={() => { setEditor(null); setReview(null); }}>{t("Cancel")}</Button></div>
        </div></div> : !items.length && !hub.loading ? <HostedListEmpty icon={<Tag size={24}/>} title={t("No release to show")} caption={t("A release's notes, installers and comparison appear here.")}/>
        : detail ? <article className="release-detail">
          <div className="release-head">
            <div className="release-version"><span className="selectable">{tag}</span><ReleaseMarkers item={detail.item} latest={detail.item.id === latest?.id}/></div>
            <div className="release-title-row">
              <h2 ref={heading} tabIndex={-1} className="selectable">{detail.item.title}</h2>
              <div className="release-actions">
                <Button disabled={busy} onClick={() => edit(true)}><Pencil size={14}/>{t("Edit")}</Button>
                {hubSafeURL(urlContext, detail.item.url) && <Button onClick={() => open(detail.item.url)}><ExternalLink size={14}/>{t("Open in browser")}</Button>}
                <HostedListIconButton label={t("More release actions")} aria-haspopup="menu" disabled={busy} onClick={event => showMenuBelow(event.currentTarget, menu(detail.item, true))}><MoreHorizontal size={14}/></HostedListIconButton>
              </div>
            </div>
            <div className="release-tagged">{releaseState(detail.item) === "Draft" && <span>{t("Not published")}</span>}{tagged && <TaggedOn value={tagged.value} commit={tagged.commit}/>}</div>
          </div>
          <div className="release-body">
            <div className="release-notes">{detail.item.body ? <ReleaseMarkdown text={detail.item.body} target={source.target} tag={tag}/> : <p className="hosted-caption">{t("No release notes.")}</p>}</div>
            <aside className="release-side">
              <ReleaseCard title={t("Installers")}>
                {groups.primary.map(asset)}
                {groups.other.length > 0 && <>
                  <button type="button" className="release-other" aria-expanded={otherFiles} onClick={() => setOtherFiles(!otherFiles)}>{otherFiles ? <ChevronDown size={12}/> : <ChevronRight size={12}/>}<span>{t("Other files")}</span><StatusPill tone="neutral">{groups.other.length.toLocaleString()}</StatusPill></button>
                  {otherFiles && groups.other.map(asset)}
                </>}
                {!detail.assets.length && <p className="hosted-caption">{t("No release assets.")}</p>}
              </ReleaseCard>
              {comparable.length > 0 && <ReleaseCard title={t("Compare")}>
                <div className="release-compare-range">
                  <label><span className="hosted-caption">{t("From")}</span><select aria-label={t("Compare from")} value={from} onChange={e => setBase(e.target.value)}>{comparable.map(item => <option key={item.id} value={releaseTag(item)}>{releaseTag(item)}</option>)}</select></label>
                  <span aria-hidden className="hosted-caption">→</span>
                  <strong className="ellipsis" title={tag}>{tag}</strong>
                </div>
                <div className="release-compare-actions">
                  {source.showRevisionComparison && <Button disabled={!from} aria-label={t("Compare {0} with {1}", from, tag)} tip={t("Opens {0} … {1} in Compare", from, tag)} onClick={() => source.showRevisionComparison?.(from, tag)}><GitCompare size={14}/>{t("Compare…")}</Button>}
                  <HostedListIconButton label={t("Compare in browser")} disabled={!comparison} onClick={() => comparison && open(comparison)}><ExternalLink size={14}/></HostedListIconButton>
                </div>
              </ReleaseCard>}
            </aside>
          </div>
        </article> : <div className="release-pending"><Spinner/></div>}
      </HostedListColumns>
    </>}
  </HostedListPage>;
}

function ReleaseCard({ title, children }: { title: string; children: ReactNode }) {
  return <section className="release-card" aria-label={title}><span className="release-card-title">{title}</span>{children}</section>;
}

/** A hash is set in monospace, a branch name is not (docs/design.md, Text) */
function TaggedOn({ value, commit }: { value: string; commit: boolean }) {
  const [before, after] = t("Tagged on {0}", "\0").split("\0");
  return <span className="selectable">{before}{commit ? <span className="mono release-sha">{value}</span> : value}{after}</span>;
}

/** Latest is a plain fact with the accent's dot; a prerelease or a draft is a state, with its reason on hover. Stable is the norm, so it gets no marker of its own. */
function ReleaseMarkers({ item, latest }: { item: HubItem; latest: boolean }) {
  const state = releaseState(item);
  return <>
    {latest && <HostedListChip icon={<i className="release-latest-dot"/>}>{t("Latest")}</HostedListChip>}
    {state !== "Stable" && <HostedListChip tone={state === "Draft" ? "neutral" : "waiting"} icon={state === "Draft" ? undefined : <Tag size={11}/>} data-tip={t(stateHelp[state])}>{t(state)}</HostedListChip>}
  </>;
}

function releaseWhen(item: HubItem): string | null {
  if (releaseState(item) === "Draft") return t("Not published");
  const at = Date.parse(releaseDate(item));
  return Number.isNaN(at) ? null : listWhen(at / 1000);
}
