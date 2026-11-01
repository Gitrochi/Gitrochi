import { Cloud } from "lucide-react";
import type { RepoStore } from "@/entities/repo";
import { CIPanel, CIRunDetail } from "@/features/ci-panel";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty } from "@/shared/ui";
import { FlowConnections } from "./FlowConnections";

/** Reuse the existing hosted CI controls, account access and run state inside Flows. */
export function FlowConnectedCI({ store }: { store: RepoStore }) {
  useObserve(store); useObserve(store.ci);
  const openSettings = () => window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: "accounts" }));
  const run = store.ci.pipelines.find((pipeline) => pipeline.id === store.ciSelected);
  return <div className="flow-connected-ci" data-flow-connected-ci>
    <header className="flow-connected-header"><Cloud size={16} /><strong>{t("Connected CI")}</strong><span className="muted">{store.target ? `${store.target.host}/${store.target.path}` : t("GitHub Actions · GitLab CI · Jenkins · Docker")}</span><span className="spacer" />{store.path && <FlowConnections repo={store.path} />}</header>
    {store.target ? <div className="flow-hosted-ci"><aside><CIPanel store={store} openSettings={openSettings} /></aside><main>{run ? <CIRunDetail store={store} pipeline={run} /> : <Empty title={t("Select a run")} detail={t("Choose a run to see its jobs and read their logs.")} />}</main></div> : <div className="flow-empty"><Empty title={t("No hosting remote")} detail={t("Open a repository with a GitHub or GitLab remote to use this workspace.")} /><Button onClick={openSettings}>{t("Connect account…")}</Button><p>{t("Configured Jenkins, HTTP and Docker modules remain available through connections and the module library.")}</p></div>}
  </div>;
}
