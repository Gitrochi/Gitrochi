import { ArrowDown, ArrowUp, ArrowLeftRight } from "lucide-react";
import type { BatchCommitAction } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, Modal, Row, Spinner } from "@/shared/ui";
import "./history-tools.css";

const closeTools = (store: RepoStore, close: () => void) => { store.cancelHistoryTools(); close(); };
/** 비교 요청 때 고정한 SHA를 파일을 바꿔 고를 때도 그대로 사용한다. */
export function CompareRevisionsSheet({ store, close, embedded = false }: { store: RepoStore; close: () => void; embedded?: boolean }) {
  useObserve(store);
  const s = store.historyTools, result = s.comparison;
  const change = () => store.changed();
  const content = <div className="history-tools col">
      <div className="row">
        <RevisionPicker title={t("From revision")} value={s.left} store={store} onChange={(value) => { s.left = value; change(); }} />
        <Button tip={t("Swap revisions")} onClick={() => { [s.left, s.right] = [s.right, s.left]; change(); }}><ArrowLeftRight size={15} /></Button>
        <RevisionPicker title={t("To revision")} value={s.right} store={store} onChange={(value) => { s.right = value; change(); }} />
        <Button kind="primary" disabled={s.comparisonLoading} onClick={() => void store.loadRevisionComparison()}>{s.comparisonLoading ? <Spinner size={14} /> : t("Compare")}</Button>
      </div>
      <label className="row hint"><input type="checkbox" checked={s.useMergeBase} onChange={(e) => { s.useMergeBase = e.target.checked; change(); }} />{t("Compare from the common ancestor (changes introduced by the right side)")}</label>
      <span className="hint">{t("Uncommitted changes are excluded. Compare fixes both revisions to immutable commits.")}</span>
      {s.comparisonError && <div role="alert" className="error-text">{s.comparisonError}</div>}
      {result && <>
        <div className="mono hint">{result.left.slice(0, 12)} → {result.right.slice(0, 12)}{result.mergeBase ? ` · ${t("Common ancestor")}: ${result.base.slice(0, 12)}` : ""} · {t("{0} files", result.files.length)}</div>
        <div className="history-tools-split">
          <div className="history-tools-list">{result.files.map((file) => <button key={file.path} className={`history-tools-file ${s.comparisonPath === file.path ? "on" : ""}`} onClick={() => void store.selectComparisonFile(file)}><span>{file.oldPath ? `${file.oldPath} → ` : ""}{file.path}</span><span className="hint">{file.kind}</span></button>)}</div>
          <pre className="history-tools-patch" tabIndex={0}>{result.files.length ? s.comparisonPatch || t("Loading…") : t("No differences between these revisions.")}</pre>
        </div>
      </>}
      {!result && !s.comparisonLoading && !s.comparisonError && <Empty title={t("Choose two revisions to compare")} detail={t("Use branches, tags or commit IDs.")} />}
    </div>;
  return embedded ? content : <Modal title={t("Compare revisions")} width={1100} onClose={() => closeTools(store, close)} footer={<Button onClick={() => closeTools(store, close)}>{t("Close")}</Button>}>{content}</Modal>;
}
/** A revision field: type a branch, tag or commit, or pick one from the list next to it (macOS: RevisionPicker) */
function RevisionPicker({ title, value, store, onChange }: { title: string; value: string; store: RepoStore; onChange: (value: string) => void }) {
  const head = store.headBranch;
  return <div className="row revision-picker">
    <input aria-label={title} className="input grow" placeholder={t("Branch, tag or commit")} value={value} onChange={(e) => onChange(e.target.value)} />
    {/* the list only fills the field, so it always shows its prompt again */}
    <select className="select revision-picker-list" aria-label={`${t("Choose a branch or tag")}: ${title}`} value="" onChange={(e) => { if (e.target.value) onChange(e.target.value); }}>
      <option value="">{t("Choose a branch or tag")}</option>
      {head && <option value={head}>{t("{0} (current)", head)}</option>}
      <option value="HEAD">HEAD</option>
      {store.localBranches.length > 0 && <optgroup label={t("Local branches")}>{store.localBranches.map((b) => <option key={b.name} value={b.name}>{b.name}</option>)}</optgroup>}
      {store.remoteBranches.length > 0 && <optgroup label={t("Remote branches")}>{store.remoteBranches.map((b) => <option key={b.name} value={b.name}>{b.name}</option>)}</optgroup>}
      {store.tags.length > 0 && <optgroup label={t("Tags")}>{store.tags.map((tag) => <option key={tag.name} value={tag.name}>{tag.name}</option>)}</optgroup>}
    </select>
  </div>;
}
const actions: Array<[BatchCommitAction, string]> = [["cherry-pick", "Cherry-pick selected commits"], ["revert", "Revert selected commits"], ["squash", "Squash selected commits"], ["drop", "Drop selected commits"]];
export function BatchCommitsSheet({ store, close }: { store: RepoStore; close: () => void }) {
  useObserve(store); const s = store.historyTools;
  const move = (index: number, delta: number) => {
    const items = [...s.batch], to = index + delta;
    if (to < 0 || to >= items.length) return;
    [items[index], items[to]] = [items[to], items[index]]; s.batch = items; store.changed();
  };
  return <Modal title={t("Review selected commits")} width={850} onClose={() => { if (!s.batchLoading) closeTools(store, close); }} footer={<>
    <Button disabled={s.batchLoading} onClick={() => closeTools(store, close)}>{t("Cancel")}</Button>
    <Button kind="primary" disabled={s.batchLoading || !!s.batchError || !s.batch.length || !!store.busy} onClick={() => void store.executeBatchCommits()}>{s.batchAction === "squash" || s.batchAction === "drop" ? t("Review cleanup plan") : t("Apply selected commits")}</Button>
  </>}>
    <div className="history-tools col">
      <Row label={t("Action")}><select className="select grow" value={s.batchAction} disabled={s.batchLoading} onChange={(e) => { s.batchAction = e.target.value as BatchCommitAction; store.changed(); }}>{actions.map(([value, label]) => <option key={value} value={value}>{t(label)}</option>)}</select></Row>
      <span className="hint">{t("Commits run from top to bottom. Cherry-pick normally uses oldest first; revert uses newest first.")}</span>
      <span className="mono hint">{s.batchBranch.replace("refs/heads/", "")} · HEAD {s.batchHead.slice(0, 12)}</span>
      {s.batchLoading && <Spinner />}
      <div className="history-tools-batch">{s.batch.map((item, i) => <div key={item.sha} className="row history-tools-batch-row"><span className="hint">{i + 1}.</span><code>{item.sha.slice(0, 8)}</code><span className="grow ellipsis" title={item.message}>{item.subject}</span><span className="hint">{item.author}</span><Button disabled={i === 0 || s.batchLoading} tip={t("Run earlier")} onClick={() => move(i, -1)}><ArrowUp size={13} /></Button><Button disabled={i === s.batch.length - 1 || s.batchLoading} tip={t("Run later")} onClick={() => move(i, 1)}><ArrowDown size={13} /></Button></div>)}</div>
      <div className="hint">{t("A clean working tree is required. A conflict stops the sequence; use Continue or Abort in the operation banner. Completed operations can be undone.")}</div>
      {(s.batchAction === "squash" || s.batchAction === "drop") && <div className="hint">{t("Cleanup rewrites history on the current branch. Squash requires adjacent commits; a second plan shows every affected commit before starting.")}</div>}
      {s.batchError && <div role="alert" className="error-text">{s.batchError}</div>}
    </div>
  </Modal>;
}
export function LineHistorySheet({ store, close }: { store: RepoStore; close: () => void }) {
  useObserve(store); const s = store.historyTools;
  const change = () => store.changed();
  const selected = s.lineEntries.find((item) => item.sha === s.lineSelected);
  return <Modal title={t("Line and function history")} width={1100} onClose={() => closeTools(store, close)} footer={<Button onClick={() => closeTools(store, close)}>{t("Close")}</Button>}>
    <div className="history-tools col">
      <Row label={t("File")}><input aria-label={t("File")} className="input grow" value={s.linePath} onChange={(e) => { s.linePath = e.target.value; change(); }} /></Row>
      <div className="row"><span>{t("Revision")}</span><input aria-label={t("Revision")} className="input grow" value={s.lineRevision} onChange={(e) => { s.lineRevision = e.target.value; change(); }} /><span>{t("Lines")}</span><input aria-label={t("First line")} className="input history-tools-number" type="number" min={1} value={s.lineStart} onChange={(e) => { s.lineStart = Number(e.target.value); change(); }} /><span>–</span><input aria-label={t("Last line")} className="input history-tools-number" type="number" min={s.lineStart} value={s.lineEnd} onChange={(e) => { s.lineEnd = Number(e.target.value); change(); }} /></div>
      <div className="row"><input aria-label={t("Function name (optional)")} className="input grow" placeholder={t("Function name (optional)")} value={s.functionName} onChange={(e) => { s.functionName = e.target.value; change(); }} /><Button kind="primary" disabled={s.lineLoading} onClick={() => void store.loadLineHistory()}>{s.lineLoading ? <Spinner size={14} /> : t("Trace history")}</Button></div>
      <span className="hint">{t("A function name replaces the line range. Git detects function boundaries using its language rules. Only committed content is traced, up to 200 commits.")}</span>
      {s.lineError && <div role="alert" className="error-text">{s.lineError}</div>}
      {s.lineTruncated && <div className="hint">{t("Output truncated. Narrow the selection.")}</div>}
      {!!s.lineEntries.length && <div className="history-tools-split"><div className="history-tools-list">{s.lineEntries.map((item) => <button key={item.sha} className={`history-tools-file ${item.sha === s.lineSelected ? "on" : ""}`} onClick={() => { s.lineSelected = item.sha; change(); }}><span>{item.subject}</span><span className="hint">{item.author} · {item.date} · {item.sha.slice(0, 8)}</span></button>)}</div><pre className="history-tools-patch" tabIndex={0}>{selected?.patch}</pre></div>}
    </div>
  </Modal>;
}
