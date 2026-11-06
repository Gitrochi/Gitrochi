import { PanelLeftOpen } from "lucide-react";
import { Plus, RefreshCw } from "@/shared/icons";
import { useEffect } from "react";
import { DiffView } from "@/widgets/diff-viewer";
import { PullRequestDetailView } from "@/widgets/inspector";
import type { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, Spinner } from "@/shared/ui";
import { PullRequestList } from "./PullRequestList";
import { PullRequestSummary } from "./PullRequestSummary";
import "./pull-requests.css";

/** One choice for all three tabs, kept across restarts; nothing else hides the list. macOS: @AppStorage("pullRequestListHidden"). */
const listHiddenSetting = "pullRequestListHidden";

/**
 * The Pull requests page: where the requests come from and the ways to refresh or open one, then the list column
 * (or the strip that brings it back) beside the selected request. (macOS: PullRequestsWorkspace.swift)
 */
export function PullRequestsWorkspace({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  useObserve(settings);
  const target = store.target;
  const targetKey = target ? `${target.provider}:${target.host}/${target.path}` : "";
  useEffect(() => { if (store.target) void store.loadPullRequests(); }, [store, targetKey]);
  if (!target) return <div className="col grow" style={{ alignItems: "center", justifyContent: "center", gap: 12 }}><Empty title={t("No hosting remote")} detail={t("Open a repository with a GitHub or GitLab remote to use this workspace.")} /><Button onClick={() => void store.pickAndOpen()}>{t("Open repository…")}</Button></div>;
  const gitlab = target.provider === "gitlab";
  const hidden = settings.get<boolean>(listHiddenSetting, false);
  const selected = store.selection?.kind === "pullRequest" ? store.selection.number : null;
  const showLabel = t(gitlab ? "Show merge request list" : "Show pull request list");
  return <div className="pr-page">
    <div className="pr-page-top">
      <span className="pr-page-where selectable">{target.host} / {target.path}</span>
      <span className="spacer" />
      {store.prState.kind === "loading" && store.pullRequests.length > 0 && <Spinner size={12} />}
      <Button className="pr-page-icon" aria-label={t("Refresh list")} tip={t("Refresh list")} onClick={() => void store.loadPullRequests()}><RefreshCw size={14} /></Button>
      <Button disabled={!store.headBranch} tip={t("New {0} from the current branch", gitlab ? "MR" : "PR")} onClick={() => store.openSheet({ kind: "createPullRequest" })}><Plus size={13} />{t(gitlab ? "New merge request…" : "New pull request…")}</Button>
    </div>
    <PullRequestSummary store={store} />
    <div className="pr-page-split">
      {hidden
        ? <aside className="pr-list-strip" aria-label={t(gitlab ? "Merge requests" : "Pull requests")}><Button className="pr-page-icon" aria-label={showLabel} aria-expanded={false} tip={t("Show list")} onClick={() => settings.set(listHiddenSetting, false)}><PanelLeftOpen size={14} /></Button></aside>
        : <PullRequestList store={store} target={target} openSettings={openSettings} onHide={() => settings.set(listHiddenSetting, true)} />}
      <div className="pr-page-detail">
        {selected == null
          ? <Empty title={t("Select a pull request")} detail={t("Search the list, then review the conversation, files and merge checks here.")} />
          : <PullRequestDetailView store={store} number={selected} page={{ listShown: !hidden, diff: (split) => <DiffView store={store} chrome={false} split={split} /> }} />}
      </div>
    </div>
  </div>;
}
