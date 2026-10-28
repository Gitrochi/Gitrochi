import { useState } from "react";
import type { RepoStore } from "@/entities/repo";
import { ipc } from "@/shared/api";
import { joinPath } from "@/shared/config";
import { t } from "@/shared/i18n";
import { screenCodeFor, workPrompts, type WorkScope } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";

/** Selection and task starters stay local until Send question is pressed. */
export function AssistantContextPanel({ store }: { store: RepoStore }) {
  const [promptID, setPromptID] = useState("");
  const [promptNotice, setPromptNotice] = useState("");
  const session = store.repositoryAssistant;
  if (!session) return null;
  const context = session.context, mapping = screenCodeFor(context.screenID);
  const disabled = session.working || session.loading || session.graphLoading;
  const openSource = async (path: string) => {
    if (!store.path || !await ipc.exists(joinPath(store.path, path))) { session.error = t("This implementation link is available when the Gitrochi source checkout is open."); store.changed(); return; }
    store.openFileHistory(path);
  };
  return <section className="col" style={{ gap: 8 }} aria-label={t("Selection context")}>
    <div className="row" style={{ flexWrap: "wrap", gap: 8 }}>
      <label className="row">{t("Scope")} <select className="input" aria-label={t("Analysis scope")} value={context.scope} disabled={disabled} onChange={(event) => store.refreshRepositorySelection(event.target.value as WorkScope)}>
        <option value="worktree">{t("Working tree")}</option><option value="staged">{t("Staged changes")}</option><option value="commits">{t("Commits")}</option>
      </select></label>
      <Button size="small" disabled={disabled} onClick={() => store.refreshRepositorySelection()}>{t("Refresh selection context")}</Button>
      <Button size="small" disabled={disabled || !session.runtime} onClick={() => void store.loadRepositoryGraph()}>{session.graphLoading ? <Spinner size={11} /> : null}{t("Load graph context")}</Button>
    </div>
    <span className="hint">{t("Screen")}: {context.screenID} · {t("Selected paths")}: {context.selectedPaths.join(", ") || t("No files selected")}</span>
    {store.repositoryContextStale && <span role="status" className="hint">{t("The selection changed. Refresh selection context before sending.")}</span>}
    <details><summary>{t("Selection context")}</summary><pre style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{JSON.stringify(context, null, 2)}</pre></details>
    <label className="row" style={{ flexWrap: "wrap", gap: 8 }}>{t("Task prompt")}<select className="input" aria-label={t("Task prompt")} value={promptID} disabled={disabled} onChange={(event) => { setPromptID(event.target.value); setPromptNotice(""); if (event.target.value) store.useRepositoryPrompt(event.target.value); }}>
      <option value="">{t("Choose a task…")}</option>{workPrompts.map((prompt) => <option key={prompt.id} value={prompt.id}>{t(prompt.title)}</option>)}
    </select></label>
    {!!promptID && <div className="row" style={{ flexWrap: "wrap", gap: 8 }}>
      <Button size="small" disabled={disabled} onClick={() => store.useRepositoryPrompt(promptID)}>{t("Use task prompt")}</Button>
      <Button size="small" disabled={disabled || store.repositoryContextStale || !session.question.trim()} onClick={() => { if (store.saveRepositoryPrompt(promptID)) setPromptNotice(t("Task prompt saved for this repository.")); }}>{t("Save task prompt")}</Button>
      <Button size="small" disabled={disabled || store.repositoryContextStale} onClick={() => { if (store.saveRepositoryPrompt(promptID, true)) setPromptNotice(t("Default task prompt restored.")); }}>{t("Reset task prompt")}</Button>
      {promptNotice && <span className="hint" role="status">{promptNotice}</span>}
    </div>}
    {session.graphSnapshot && <>
      <span className="hint">{t("Working file graph")}: {session.graphSnapshot.nodeIDs.length} · {t("Graph context is bounded. Omitted files and edges are not evidence of absence.")}</span>
      <label className="row" style={{ flexWrap: "wrap", gap: 8 }}>{t("Graph node")}<select className="input" style={{ maxWidth: "100%" }} aria-label={t("Graph node")} value={store.workSelectedNodeIDs[0] ?? ""} disabled={disabled} onChange={(event) => { store.workSelectedNodeIDs = event.target.value ? [event.target.value] : []; store.refreshRepositorySelection(); }}>
        <option value="">{t("No node selected")}</option>{session.graphSnapshot.nodeIDs.map((id) => <option key={id} value={id}>{id}</option>)}
      </select></label>
      <details><summary>{t("Graph coverage and snapshot")}</summary><pre style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{session.graphCoverage}</pre></details>
    </>}
    <details><summary>{t("Screen implementation map")}</summary>
      <span className="hint">{t("Maintained Gitrochi source links; these are not inferred dependencies.")}</span>
      {mapping ? <div className="col">{[...mapping.macOS, ...mapping.windows, ...mapping.tests].map((path) => <Button key={path} size="small" onClick={() => void openSource(path)}>{path}</Button>)}</div> : <span className="hint">{t("This screen has no maintained source mapping yet.")}</span>}
    </details>
  </section>;
}
