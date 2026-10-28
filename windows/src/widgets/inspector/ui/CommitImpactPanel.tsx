import { ExternalLink, RefreshCw, Route, TriangleAlert } from "lucide-react";
import type { ReactNode } from "react";
import type { GraphReviewImpact } from "@/entities/gitch";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button, Card, Spinner } from "@/shared/ui";
import { reviewChangeStatusLabel } from "../lib/commit-impact";

/** 커밋 준비 화면에서 요청할 때만 분석한다. 테스트 후보와 실행 결과를 구별해서 표시한다. */
export function CommitImpactPanel({ store }: { store: RepoStore }) {
  const state = store.commitImpact;
  const n = store.status.staged.length;
  if (!n && !state) return null;
  const running = state?.kind === "running";
  const result = state?.kind === "done" ? state.result : null;
  const stale = store.commitImpactStale;
  return (
    <Card className="commit-impact" gap={8}>
      <div className="row" style={{ flexWrap: "wrap" }}>
        <Route size={15} />
        <span style={{ fontWeight: 600 }}>{t("Change impact")}</span>
        <span className="spacer" />
        <Button size="small" disabled={!n || running || !!store.busy || store.status.conflicted.length > 0} onClick={() => void store.analyzeCommitImpact()}>
          {running ? <Spinner size={11} /> : <RefreshCw size={12} />}
          {running ? t("Analyzing…") : result || state?.kind === "failed" ? t("Analyze again") : t("Analyze staged files")}
        </Button>
      </div>
      <span className="hint">{t("Staged contents compared with HEAD. Unstaged edits are excluded.")}</span>
      {running && <span className="hint" role="status">{t("Finding affected files and related test candidates…")}</span>}
      {state?.kind === "failed" && <div className="commit-impact-notice" role="alert"><TriangleAlert size={14} /><span>{state.message}</span></div>}
      {!n && <span className="hint">{t("Stage files to analyze the next commit.")}</span>}
      {store.status.conflicted.length > 0 && <span className="hint">{t("Resolve conflicts before analyzing staged changes.")}</span>}
      {result && <>
        {store.commitImpactVerifying ? <span className="hint row" role="status"><Spinner size={11} />{t("Checking staged changes…")}</span>
          : stale && <div className="commit-impact-notice" role="status"><TriangleAlert size={14} /><span>{t("The staged contents or HEAD changed. Analyze again before using this result.")}</span></div>}
        {state?.kind === "done" && state.notice && <div className="commit-impact-notice" role="alert"><TriangleAlert size={14} /><span>{state.notice}</span></div>}
        <div className={stale || store.commitImpactVerifying ? "commit-impact-result outdated" : "commit-impact-result"}>
          <span className="hint">{t("Analyzed {0} of {1} changed files", result.coverage.analyzed, result.coverage.changed)}</span>
          {result.coverage.unsupported > 0 && <span className="hint">{t("{0} changed files could not be analyzed. The impact may be incomplete.", result.coverage.unsupported)}</span>}
          <ImpactGroup title={t("Changed files")} count={result.changed.length} empty={t("No staged changes were found.")}>
            {result.changed.map((file) => <div className="commit-impact-file" key={file.path}>
              <span className="mono">{file.path}</span>
              <span className="hint">{reviewChangeStatusLabel(file.status)}{file.oldPath && ` · ${t("Renamed from {0}", file.oldPath)}`}{!file.analyzed && ` · ${t("Not analyzed")}`}</span>
            </div>)}
          </ImpactGroup>
          <ImpactGroup title={t("Directly affected files")} count={result.direct.length} empty={t("No direct dependents were found.")}>
            {result.direct.map((file) => <AffectedFile key={file.path} file={file} />)}
          </ImpactGroup>
          <ImpactGroup title={t("Indirectly affected files")} count={result.indirect.length} empty={t("No indirect dependents were found.")}>
            {result.indirect.map((file) => <AffectedFile key={file.path} file={file} />)}
          </ImpactGroup>
          <ImpactGroup title={t("Related test candidates")} count={result.tests.length} empty={t("No related test candidates were found.")}>
            {result.tests.map((file) => <div className="commit-impact-file" key={file.path}>
              <span className="mono">{file.path}</span>
              <span className="hint">{file.kind === "name" ? t("Name match · inferred") : file.heuristic ? t("Dependency match · inferred") : t("Dependency match")}</span>
            </div>)}
          </ImpactGroup>
        </div>
        <span className="hint">{t("Candidates come from dependencies or file names. Tests have not been run.")}</span>
        <Button size="small" onClick={() => { store.openSheet({ kind: "workValidation" }); }}>{t("Connect verification evidence…")}</Button>
        {result.limitations.length > 0 && <details className="commit-impact-group"><summary>{t("Analysis limitations")} · {result.limitations.length}</summary><ul className="hint">{result.limitations.map((line, i) => <li key={i}>{t(line)}</li>)}</ul></details>}
        <Button size="small" disabled={stale || store.commitImpactVerifying || !!store.graphJob || !result.changed.length} onClick={() => void store.openCommitImpactGraph()}>
          {store.graphJob?.kind === "review" ? <Spinner size={11} /> : <ExternalLink size={12} />}{t("View staged impact as graph")}
        </Button>
      </>}
    </Card>
  );
}

function ImpactGroup({ title, count, empty, children }: { title: string; count: number; empty: string; children: ReactNode }) {
  return <details className="commit-impact-group" open={count <= 4}>
    <summary>{title}<span className="muted">{count}</span></summary>
    {count ? <div className="commit-impact-files">{children}</div> : <span className="hint">{empty}</span>}
  </details>;
}

function AffectedFile({ file }: { file: GraphReviewImpact }) {
  return <div className="commit-impact-file">
    <span className="mono">{file.path}</span>
    <span className="hint">{file.via.length > 0 ? t("Via {0}", file.via.join(", ")) : t("Dependency match")}{file.heuristic && ` · ${t("Inferred")}`}</span>
  </div>;
}
