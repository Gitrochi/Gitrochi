import { Fragment, useEffect, useMemo, useState } from "react";
import { GitCompare, Tag } from "@/shared/icons";
import { releaseTag, releaseTaggedOn, releaseTimeline, type HubItem, type HubSource } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { git } from "@/shared/platform";
import { Button, HostedListSummary } from "@/shared/ui";

type Distances = { segments: (number | null)[]; ahead: number | null; behind: number | null; prereleaseInHead: boolean };
// Square roots keep a 200-commit gap from flattening the 10-commit ones next to it.
const grow = (commits: number | null | undefined) => commits == null ? 3 : Math.max(1, Math.sqrt(commits));
const nothing: Distances = { segments: [], ahead: null, behind: null, prereleaseInHead: false };

/**
 * What this branch has not released yet and the way there (macOS: ReleaseWorkspace.summary). Without the tag in this
 * clone the distance is unknown, so the card says what it does know: the newest release.
 */
export function ReleaseSummary({ source, items, family }: { source: HubSource; items: HubItem[]; family: string }) {
  const timeline = useMemo(() => releaseTimeline(items, family), [items, family]);
  // the line runs up to the newest stable release; a newer prerelease sits beside it, not on it
  const fork = timeline.stable ? timeline.prerelease : undefined;
  const line = timeline.path.filter(item => item !== fork);
  const tags = line.map(releaseTag), forkTag = fork && releaseTag(fork), key = [source.path, source.headHash, ...timeline.path.map(releaseTag)].join("\n");
  const [distances, setDistances] = useState<{ key: string; value: Distances } | null>(null);
  useEffect(() => {
    const repo = source.path, head = source.headHash;
    if (!repo || !tags.length) return;
    let active = true;
    // refs/tags/ keeps a server-supplied tag from being read as an option or a branch
    const count = async (range: string) => { const result = await git(["rev-list", "--count", range], repo, { ok: [0, 128] }); return result.status === 0 ? Number(result.stdout.trim()) : null; };
    const sides = async (tag: string) => { const result = head ? await git(["rev-list", "--left-right", "--count", `refs/tags/${tag}...${head}`], repo, { ok: [0, 128] }) : null; return result?.status === 0 ? result.stdout.trim().split(/\s+/).map(Number) : [null, null]; };
    void (async () => {
      const segments = await Promise.all(tags.slice(1).map((tag, index) => count(`refs/tags/${tags[index]}..refs/tags/${tag}`)));
      const [behind, ahead] = await sides(tags[tags.length - 1]);
      const prereleaseInHead = forkTag ? (await sides(forkTag))[0] === 0 : false;
      if (active) setDistances({ key, value: { segments, ahead, behind, prereleaseInHead } });
    })().catch(() => { if (active) setDistances({ key, value: nothing }); });
    return () => { active = false; };
  }, [key]);
  const latest = timeline.stable ?? timeline.prerelease;
  if (!latest) return null;
  const tag = releaseTag(latest), value = !source.path ? nothing : distances?.key === key ? distances.value : null;
  const unknown = !!value && value.ahead == null;
  const atLast = value?.ahead === 0 && value.behind === 0;
  const hasHead = !atLast && !!source.headHash;
  const ahead = value?.ahead ?? 0;
  const headline = !value ? t("Loading…") : ahead === 0 ? t("Nothing unreleased") : ahead === 1 ? t("1 commit on this branch") : t("{0} commits on this branch", ahead.toLocaleString());
  const name = !unknown ? t("Unreleased") : t(timeline.stable && timeline.prerelease ? "Latest stable release" : "Latest release");
  const caption = value?.behind ? t("Not on top of {0}", tag) : t("since {0}", tag);
  const tagged = fork && releaseTaggedOn(undefined, String(fork.data.target_commitish ?? ""));
  // a branch says where it sits; a bare commit says nothing a reader could use
  const forkCaption = tagged && !tagged.commit ? t("Prerelease · on {0}", tagged.value) : t("Prerelease");
  const compare = source.showRevisionComparison && value?.ahead != null && !atLast
    ? <Button aria-label={t("Compare {0} with this branch", tag)} tip={t("Opens {0} … {1} in Compare", tag, "HEAD")} onClick={() => source.showRevisionComparison?.(tag, source.headHash ?? "HEAD")}><GitCompare size={14}/>{t("Compare…")}</Button>
    : null;
  const label = [...tags, ...(hasHead ? ["HEAD"] : []), ...(fork ? [forkTag, forkCaption] : [])].join(", ");
  return <HostedListSummary
    label={t("Versions")}
    lead={<>
      <span className="hosted-summary-key">{name}</span>
      {unknown ? <><span className="hosted-summary-value">{tag}</span><span className="hosted-caption ellipsis" title={latest.title}>{latest.title}</span></>
        : value ? <><span className="hosted-summary-value">{headline}</span><span className="hosted-caption ellipsis">{caption}</span></>
        : <span className="hosted-caption">{headline}</span>}
    </>}
    middle={source.path ? <div className="release-track-box"><div className="release-track" role="img" aria-label={label}>
      {line.map((item, index) => {
        const last = index === line.length - 1, back = line.length - 1 - index;
        return <Fragment key={item.id}>
          {index > 0 && <span className="release-tseg" data-back={back + 1} style={{ flexGrow: grow(value?.segments[index - 1]) }}/>}
          <span className="release-node" data-kind={!last ? "older" : atLast ? "head" : "latest"} data-back={back}><span className="release-node-dot"><i/></span><span className="release-node-label ellipsis" title={tags[index]}>{tags[index]}</span></span>
        </Fragment>;
      })}
      {hasHead && <>
        <span className="release-tseg dashed" style={{ flexGrow: grow(value?.ahead) }}>
          {fork && <>
            {!value?.prereleaseInHead && <span className="release-fork-curve"/>}
            <span className={`release-fork${value?.prereleaseInHead ? " on-line" : ""}`}><i/><span className="release-fork-text"><span>{forkTag}</span><span className="hosted-caption">{forkCaption}</span></span></span>
          </>}
        </span>
        <span className="release-node" data-kind="head"><span className="release-node-dot"><i/></span><span className="release-node-label" title={source.headBranch || source.headHash?.slice(0, 8) || "HEAD"}>HEAD</span></span>
      </>}
    </div></div> : null}
    trail={compare}
    strip={<>
      <Tag size={14}/>
      <span className="hosted-caption" style={{ flex: "none" }}>{name}</span>
      <span className="hosted-strip-text">{unknown ? tag : headline}</span>
      <span className="spacer"/>
      {compare}
    </>}
  />;
}
