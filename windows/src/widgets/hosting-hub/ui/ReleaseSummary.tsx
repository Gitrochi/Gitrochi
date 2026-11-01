import { Fragment, useEffect, useMemo, useState } from "react";
import { GitCompare } from "lucide-react";
import { releaseDate, releaseState, releaseTag, releaseTimeline, type HubItem, type HubSource } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { git } from "@/shared/platform";
import { Button, HostingDate } from "@/shared/ui";

type Distances = { segments: (number | null)[]; ahead: number | null; behind: number | null };
// Square roots keep a 200-commit gap from flattening the 10-commit ones next to it.
const grow = (commits: number | null | undefined) => commits == null ? 3 : Math.max(1, Math.sqrt(commits));

/** The newest release of a package and where the checkout stands after it (macOS: ReleaseWorkspace.summary). */
export function ReleaseSummary({ source, items, family }: { source: HubSource; items: HubItem[]; family: string }) {
  const timeline = useMemo(() => releaseTimeline(items, family), [items, family]);
  const tags = timeline.path.map(releaseTag), key = [source.path, source.headHash, ...tags].join("\n");
  const [distances, setDistances] = useState<{ key: string; value: Distances } | null>(null);
  useEffect(() => {
    const repo = source.path, head = source.headHash;
    if (!repo || !tags.length) return;
    let active = true;
    // refs/tags/ keeps a server-supplied tag from being read as an option or a branch
    const count = async (range: string) => { const result = await git(["rev-list", "--count", range], repo, { ok: [0, 128] }); return result.status === 0 ? Number(result.stdout.trim()) : null; };
    void (async () => {
      const segments = await Promise.all(tags.slice(1).map((tag, index) => count(`refs/tags/${tags[index]}..refs/tags/${tag}`)));
      const sides = head ? await git(["rev-list", "--left-right", "--count", `refs/tags/${tags[tags.length - 1]}...${head}`], repo, { ok: [0, 128] }) : null;
      const [behind, ahead] = sides?.status === 0 ? sides.stdout.trim().split(/\s+/).map(Number) : [null, null];
      if (active) setDistances({ key, value: { segments, ahead, behind } });
    })().catch(() => { if (active) setDistances({ key, value: { segments: [], ahead: null, behind: null } }); });
    return () => { active = false; };
  }, [key]);
  const latest = timeline.stable ?? timeline.prerelease;
  if (!latest) return null;
  const value = distances?.key === key ? distances.value : null, last = timeline.path[timeline.path.length - 1];
  const atLast = value?.ahead === 0 && value.behind === 0;
  const head = source.headBranch || source.headHash?.slice(0, 8) || "HEAD";
  const status = value?.ahead == null ? "" : value.behind ? t("Not on top of {0}", releaseTag(last)) : value.ahead ? t("{0} unreleased commits", value.ahead.toLocaleString()) : "";
  return <section className="release-summary" aria-label={t("Versions")}>
    <div className="release-summary-latest"><span>{t(timeline.stable && timeline.prerelease ? "Latest stable release" : "Latest release")}</span><strong>{releaseTag(latest)}</strong><small title={latest.title}>{latest.title}</small><HostingDate value={releaseDate(latest)} published/></div>
    {source.path && <div className="release-timeline">
      {timeline.path.map((item, index) => <Fragment key={item.id}>
        {index > 0 && <span className="release-segment" style={{ flexGrow: grow(value?.segments[index - 1]) }}/>}
        <span className={`release-node ${item === timeline.stable ? "latest" : releaseState(item) === "Prerelease" ? "prerelease" : ""}`}><span className="release-node-label" title={releaseTag(item)}><span>{releaseTag(item)}</span>{atLast && item === last && <small>{head}</small>}</span></span>
      </Fragment>)}
      {!atLast && source.headHash && <>
        <span className="release-segment unreleased" style={{ flexGrow: grow(value?.ahead) }}>{status && <span className="release-segment-label">{status}</span>}</span>
        <span className="release-node head"><span className="release-node-label" title={head}><span>{head}</span><small>{source.headHash.slice(0, 8)}</small></span></span>
      </>}
    </div>}
    {source.showRevisionComparison && value?.ahead != null && !atLast && <div className="release-summary-action">
      <Button onClick={() => source.showRevisionComparison?.(releaseTag(latest), source.headHash ?? "HEAD")}><GitCompare size={14}/>{t("Compare changes")}</Button>
      <small title={`${releaseTag(latest)} → ${head}`}>{releaseTag(latest)} → {head}</small>
    </div>}
  </section>;
}
