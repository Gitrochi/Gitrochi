import { Play } from "lucide-react";
import { Globe } from "@/shared/icons";
import { ChevronLeft, PanelRight, RefreshCw } from "@/shared/icons";
import { runHistory } from "@/entities/ci";
import type { RepoStore } from "@/entities/repo";
import { CIPanel, CIRunDetail, RunSummary, useRuns } from "@/features/ci-panel";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, HostedAccountNeeded, HostedListColumns, HostedListEmpty, HostedListHeader, HostedListIconButton, HostedListPage } from "@/shared/ui";

/**
 * Actions, as the redesign's Actions board draws it: where the page is and its actions, how this branch's runs went,
 * then the run list and the selected run with its jobs and a job's log beside it. The page fills the window; only the
 * list column keeps its width. (macOS: ActionsWorkspacePanel)
 */
export function ActionsWorkspacePanel({ store, openSettings }: { store: RepoStore; openSettings?: () => void }) {
  useObserve(store);
  const ci = useObserve(store.ci);
  const settingsOpener =
    openSettings ??
    (() =>
      window.dispatchEvent(
        new CustomEvent("gitrochi-open-settings", { detail: "accounts" }),
      ));
  useRuns(store);
  const target = store.target;
  if (!target)
    return (
      <HostedListPage>
        <HostedListEmpty icon={<Globe size={24} />} title={t("No hosting remote")} caption={t("Open a repository with a GitHub or GitLab remote to use this workspace.")}
          action={{ label: t("Connect account…"), filled: true, onClick: settingsOpener }} />
      </HostedListPage>
    );
  const run = ci.pipelines.find((p) => p.id === store.ciSelected);
  const history = runHistory(ci.pipelines, ci.currentRef), latest = history[history.length - 1];
  return (
    <HostedListPage className="actions-page">
      <HostedListHeader host={target.host} path={target.path}>
        <HostedListIconButton label={t("Refresh")} disabled={ci.state.kind === "loading"} onClick={() => void ci.load()}><RefreshCw size={14} /></HostedListIconButton>
        <Button
          tip={target.provider === "gitlab" ? t("Run new pipeline|Choose a branch and variables to run") : t("Run workflow|Runs a workflow_dispatch workflow with a branch and inputs")}
          disabled={!ci.hasAccess || ci.busy.has("run")}
          onClick={() => { store.sheet = { kind: "runPipeline" }; store.changed(); }}
        >
          <Play size={12} fill="currentColor" />{target.provider === "gitlab" ? t("Run pipeline…") : t("Run workflow…")}
        </Button>
      </HostedListHeader>
      {ci.state.kind === "needsAccount" ? (
        <HostedAccountNeeded gitlab={target.provider === "gitlab"} host={target.host} path={target.path} onConnect={settingsOpener} />
      ) : (
        <>
          <RunSummary store={store} />
          <HostedListColumns detail={!!run} list={<CIPanel store={store} openSettings={settingsOpener} page />}>
            {run ? (
              <>
                <div className="hosted-back">
                  <Button onClick={() => { store.ciSelected = null; store.changed(); }}><ChevronLeft size={14} />{t("Back to runs")}</Button>
                </div>
                <CIRunDetail store={store} pipeline={run} />
              </>
            ) : (
              <HostedListEmpty icon={<PanelRight size={24} />} title={t("Select a run")} caption={t("Choose a run to see its jobs and read their logs.")}
                action={latest ? { label: t("Show this branch's latest run"), filled: true, onClick: () => store.selectRun(latest) } : undefined} />
            )}
          </HostedListColumns>
        </>
      )}
    </HostedListPage>
  );
}
