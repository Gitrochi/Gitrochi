import { useEffect, useState } from "react";
import { ArrowLeftRight, CircleCheck, Cloud, GitBranch, Search, Tag as TagIcon } from "lucide-react";
import type { RepoStore } from "@/entities/repo";
import { RevisionPicker } from "@/features/history-tools";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, Spinner } from "@/shared/ui";
import "./local-workbench.css";

/**
 * The Compare page: the revision pickers and a branch list on the left, the comparison on the right.
 * The "Compare revisions…" dialog keeps its own one-column layout. (macOS: RevisionComparisonPanel)
 */
export function RevisionComparisonPanel({ store }: { store: RepoStore }) {
  useObserve(store);
  const [query, setQuery] = useState("");
  useEffect(() => () => store.cancelHistoryTools(), [store]);
  const s = store.historyTools, result = s.comparison;
  const change = () => store.changed();
  const needle = query.trim().toLowerCase();
  // the current branch first, then the other local branches, remote branches and tags
  const rows = [
    ...[...store.localBranches].sort((a, b) => Number(b.isCurrent) - Number(a.isCurrent)).map((b) => ({ key: "local:" + b.name, name: b.name, icon: b.isCurrent ? <CircleCheck size={14} /> : <GitBranch size={14} /> })),
    ...store.remoteBranches.map((b) => ({ key: "remote:" + b.name, name: b.name, icon: <Cloud size={14} /> })),
    ...store.tags.map((tag) => ({ key: "tag:" + tag.name, name: tag.name, icon: <TagIcon size={14} /> })),
  ].filter((row) => !needle || row.name.toLowerCase().includes(needle));
  const compareWith = (name: string) => { s.left = store.headBranch ?? "HEAD"; s.right = name; change(); void store.loadRevisionComparison(); };
  return <section className="local-workbench compare-page">
    <aside className="compare-side">
      <div className="compare-form">
        <RevisionPicker title={t("From revision")} value={s.left} store={store} onChange={(value) => { s.left = value; change(); }} />
        <Button className="compare-swap" tip={t("Swap revisions")} onClick={() => { [s.left, s.right] = [s.right, s.left]; change(); }}><ArrowLeftRight size={15} /></Button>
        <RevisionPicker title={t("To revision")} value={s.right} store={store} onChange={(value) => { s.right = value; change(); }} />
        <label className="row hint"><input type="checkbox" checked={s.useMergeBase} onChange={(e) => { s.useMergeBase = e.target.checked; change(); }} />{t("Compare from the common ancestor (changes introduced by the right side)")}</label>
        <Button kind="primary" block disabled={s.comparisonLoading || !s.left.trim() || !s.right.trim()} onClick={() => void store.loadRevisionComparison()}>{s.comparisonLoading ? <Spinner size={14} /> : t("Compare")}</Button>
        {s.comparisonError && <div role="alert" className="error-text">{s.comparisonError}</div>}
      </div>
      <div className="compare-branches">
        <strong>{t("Branches")}</strong>
        <div className="row"><Search size={14} className="muted" /><input className="input grow" aria-label={t("Filter branches and tags")} placeholder={t("Filter branches and tags")} value={query} onChange={(e) => setQuery(e.target.value)} /></div>
        <div className="compare-branch-list">
          {rows.map((row) => <div key={row.key} className={`compare-branch${s.right === row.name ? " on" : ""}`} data-ref={row.name}>
            <span className="muted compare-branch-icon">{row.icon}</span>
            <span className="ellipsis grow" title={row.name}>{row.name}</span>
            <Button size="small" disabled={s.comparisonLoading} onClick={() => compareWith(row.name)}>{t("Compare")}</Button>
          </div>)}
          {!rows.length && <p className="hint">{t("No matching branches")}</p>}
        </div>
      </div>
    </aside>
    <main className="compare-main">
      {result ? <>
        <div className="mono hint">{result.left.slice(0, 12)} → {result.right.slice(0, 12)}{result.mergeBase ? ` · ${t("Common ancestor")}: ${result.base.slice(0, 12)}` : ""} · {t("{0} files", result.files.length)}</div>
        <div className="compare-result">
          <div className="history-tools-list">{result.files.map((file) => <button key={file.path} className={`history-tools-file ${s.comparisonPath === file.path ? "on" : ""}`} onClick={() => void store.selectComparisonFile(file)}><span>{file.oldPath ? `${file.oldPath} → ` : ""}{file.path}</span><span className="hint">{file.kind}</span></button>)}</div>
          <pre className="history-tools-patch" tabIndex={0}>{result.files.length ? s.comparisonPatch || t("Loading…") : t("No differences between these revisions.")}</pre>
        </div>
      </> : <div className="compare-empty">{s.comparisonLoading ? <Spinner /> : <Empty title={t("Choose two revisions to compare")} detail={t("Use branches, tags or commit IDs, or pick a branch on the left.")} />}</div>}
    </main>
  </section>;
}
