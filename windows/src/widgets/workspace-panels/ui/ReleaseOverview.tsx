import { RefreshCw, Tag } from "lucide-react";
import { workspace } from "@/entities/workspace";
import { accounts, releasePortfolio, newestReleases, releaseTag, releaseDate, releaseFamily } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button } from "@/shared/ui";
import "./release-overview.css";

/** Only open repositories participate; visiting Home does not contact their servers. */
export function ReleaseOverview() {
  useObserve(workspace); useObserve(releasePortfolio); useObserve(accounts);
  const sources = workspace.tabs.filter(tab => tab.path && tab.target);
  if (!sources.length) return null;
  const checking = sources.some(source => releasePortfolio.entry(source).status === "Checking releases…");
  return <section className="release-overview" aria-label={t("Repository releases")}>
    <div className="release-overview-header"><div><h2>{t("Repository releases")}</h2><p className="hint">{t("Check versions across your open repositories.")}</p></div><Button disabled={checking} onClick={() => void releasePortfolio.refresh(sources)}><Tag size={14}/>{t("Check releases")}</Button><Button disabled={checking} tip={t("Refresh")} aria-label={t("Refresh")} onClick={() => void releasePortfolio.refresh(sources, true)}><RefreshCw size={14}/></Button></div>
    <div className="release-overview-grid">{sources.map(source => {
      const summary = releasePortfolio.entry(source), latest = newestReleases(summary.page?.items ?? []);
      const packages = new Set(summary.page?.items.map(releaseFamily));
      return <article key={source.id} className="release-overview-card"><div><strong>{source.target!.path}</strong><p className="hint">{source.target!.host} · @{source.hostingAccount?.username ?? "—"}</p></div>
        <span className="release-overview-status" role="status">{t(summary.status)}</span>
        {summary.status === "Ready" && (packages.size > 1 ? <p className="hint">{t("Multiple packages; open releases to choose one.")}</p> : <div><span className="hint">{t(summary.page?.more ? "Newest loaded stable" : "Latest stable by date")}</span><p className="release-overview-version">{latest.stable ? releaseTag(latest.stable) : "—"}</p>{latest.stable && <time className="hint">{releaseDate(latest.stable).slice(0, 10)}</time>}{latest.prerelease && <p className="hint">{t("Prerelease")}: {releaseTag(latest.prerelease)}</p>}</div>)}
        {summary.error && <p className="hint" role="alert">{summary.error}</p>}
        {summary.checkedAt && <p className="hint">{t("Last checked")}: <time>{new Date(summary.checkedAt).toLocaleString()}</time></p>}
        <Button onClick={() => { source.navigate("releases"); workspace.select(source.id); }}>{t("Open releases")}</Button>
      </article>;
    })}</div>
  </section>;
}
