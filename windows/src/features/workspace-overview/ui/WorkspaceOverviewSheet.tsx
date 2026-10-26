import { useState } from "react";
import { statusCount } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { workspace } from "@/entities/workspace";
import { basename, recents, samePath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Modal, Spinner } from "@/shared/ui";

export function WorkspaceOverviewSheet({ close }: { store: RepoStore; close: () => void }) {
  useObserve(workspace);
  const [refreshing, setRefreshing] = useState(new Set<string>());
  const repositories = workspace.tabs.filter((s) => !!s.path);
  const recent = recents().filter((p) => !repositories.some((s) => samePath(s.path, p))).slice(0, 12);
  const refresh = async (repository: RepoStore) => {
    setRefreshing((old) => new Set(old).add(repository.id));
    try { await repository.ci.load(false, false); await repository.loadInbox("review"); }
    finally { setRefreshing((old) => new Set([...old].filter((id) => id !== repository.id))); }
  };
  return <Modal title={t("Workspace overview")} width={950} onClose={close} footer={<><span className="spacer" /><Button onClick={close}>{t("Close")}</Button></>}>
    <span className="hint">{t("Local status updates automatically for open repositories. Hosting summaries use the selected account for each repository and refresh only when requested.")}</span>
    <div className="col" style={{ maxHeight: 560, overflow: "auto", gap: 10 }}>
      {repositories.map((repository) => {
        const pipeline = repository.headHash ? repository.ci.bySha.get(repository.headHash) : null;
        return <div key={repository.id} className="col" style={{ gap: 8, padding: 12, background: "var(--bg)", border: "1px solid var(--border)", borderRadius: 8 }}>
          <div className="row" style={{ gap: 8 }}><div className="col grow"><strong>{repository.name}</strong><span className="hint" style={{ userSelect: "text", overflowWrap: "anywhere" }}>{repository.path}</span></div>{refreshing.has(repository.id) && <Spinner size={14} />}<Button onClick={() => { close(); workspace.select(repository.id); }}>{t("Open repository")}</Button></div>
          <div className="row" style={{ gap: 16, flexWrap: "wrap" }}><span className="mono">{repository.headBranch ?? t("Detached HEAD")}</span><span>{t("{0} modified files", statusCount(repository.status))}</span><span>↑{repository.status.ahead} ↓{repository.status.behind}</span><span className="muted">{repository.gitchStatus?.account}</span></div>
          <div className="row" style={{ gap: 12, flexWrap: "wrap" }}>
            <span style={{ color: pipeline?.status === "failed" ? "var(--red)" : undefined }}>{pipeline ? `CI: ${pipeline.status}` : t("CI not loaded")}</span>
            <span className="hint">{repository.inboxKind === "review" ? t("{0} review requests loaded", repository.inboxItems.length) : t("Review requests not loaded")}</span>
            <span className="spacer" /><Button size="small" disabled={!repository.target || refreshing.has(repository.id)} onClick={() => void refresh(repository)}>{t("Refresh hosting summaries")}</Button>
            <Button size="small" disabled={!repository.target} onClick={() => { close(); workspace.select(repository.id); repository.openSheet({ kind: "collaborationInbox" }); }}>{t("Issues and mentions")}</Button>
          </div>
          {repository.inboxError && <span className="hint" style={{ color: "var(--red)" }}>{repository.inboxError}</span>}
        </div>;
      })}
      {recent.map((path) => <div key={path} className="row" style={{ gap: 8, padding: 12 }}><div className="col grow"><strong>{basename(path)}</strong><span className="hint" style={{ userSelect: "text" }}>{path}</span></div><Button onClick={() => { close(); void workspace.openInNewTab(path); }}>{t("Open repository")}</Button></div>)}
    </div>
  </Modal>;
}
