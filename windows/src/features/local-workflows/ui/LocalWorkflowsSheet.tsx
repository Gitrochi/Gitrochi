import { useEffect, useState } from "react";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Modal } from "@/shared/ui";
import "./local-workflows.css";

/** 읽기는 로컬에서 끝내고 서버 연결은 사용자가 선택한 작업에서만 한다. */
export function LocalWorkflowsSheet({ store, close }: { store: RepoStore; close: () => void }) {
  useObserve(store);
  const [tab, setTab] = useState("Recovery");
  const [branch, setBranch] = useState("recovered-work");
  const [pattern, setPattern] = useState("");
  const [lockPath, setLockPath] = useState("");
  const [good, setGood] = useState("");
  const [bad, setBad] = useState("HEAD");
  useEffect(() => { void store.loadLocalWorkflows(); }, [store]);
  const state = store.localWorkflows;
  const disabled = !!store.busy || state.loading;
  const task = (operation: () => Promise<unknown>) => { void operation().catch((e: unknown) => { state.error = String(e instanceof Error ? e.message : e); store.changed(); }); };
  return <Modal title={t("Repository tools")} width={1000} onClose={close} footer={<><Button disabled={disabled} onClick={() => task(() => store.loadLocalWorkflows())}>{t("Refresh")}</Button><span className="spacer" /><Button onClick={close}>{t("Close")}</Button></>}>
    <div className="local-workflows">
      <div className="row local-tabs">{["Recovery", "LFS", "Submodules", "Bisect"].map((name) => <Button key={name} kind={tab === name ? "primary" : "default"} onClick={() => setTab(name)}>{t(name)}</Button>)}</div>
      {(state.error || store.errorMessage) && <div role="alert" className="local-error">{state.error || store.errorMessage}</div>}
      {state.notice && <p className="hint">{state.notice}</p>}
      {tab === "Recovery" && <>
        <p className="hint">{t("Discarded changes are saved locally before removal. Copies keep binary files, new files, symlinks, and the index. Restore at the original commit with a clean working tree.")}</p>
        <h3>{t("Saved working trees")}</h3>
        {!state.recovery.length && <p className="muted">{t("No safety copies yet.")}</p>}
        {state.recovery.map((entry) => <div className="local-entry row" key={entry.id}><span className="grow">{new Date(entry.created).toLocaleString()} · {entry.head.slice(0, 8)}</span><Button size="small" onClick={() => task(() => store.previewRecovery(entry))}>{t("Preview changes")}</Button><Button size="small" disabled={disabled} onClick={() => task(() => store.restoreSafetyCopy(entry))}>{t("Restore safety copy")}</Button></div>)}
        {state.preview && <pre className="local-preview">{state.preview}</pre>}
        <h3>{t("Reflog recovery")}</h3><p className="hint">{t("Recover a commit into a new branch. Your current branch and working files stay in place. Git controls reflog retention.")}</p>
        <input className="input" aria-label={t("Recovery branch name")} value={branch} onChange={(e) => setBranch(e.target.value)} />
        <div className="local-list">{state.reflog.map((entry, i) => <div className="local-entry row" key={`${entry.selector}-${i}`}><code>{entry.sha.slice(0, 8)}</code><span className="grow">{entry.message}<small>{entry.selector} · {entry.date}</small></span><Button size="small" disabled={disabled || !branch.trim()} onClick={() => task(() => store.recoverCommit(entry.sha, branch))}>{t("Create recovery branch")}</Button></div>)}</div>
      </>}
      {tab === "LFS" && <>
        {!state.lfsAvailable ? <p>{t("Git LFS is not installed. Install Git LFS for your platform, then refresh.")}</p> : <>
          <p className="hint">{t("Tracking changes .gitattributes for future additions. Existing history is not migrated. Review and commit the attribute change yourself.")}</p>
          <div className="row"><input className="input grow" placeholder="*.psd" aria-label={t("LFS pattern")} value={pattern} onChange={(e) => setPattern(e.target.value)} /><Button disabled={disabled || !pattern.trim()} onClick={() => task(() => store.lfsTrack(pattern))}>{t("Track pattern")}</Button><Button disabled={disabled || !pattern.trim()} onClick={() => task(() => store.lfsTrack(pattern, true))}>{t("Untrack pattern")}</Button><Button disabled={disabled} onClick={() => task(() => store.checkLfs())}>{t("Check local objects")}</Button></div>
          <pre className="local-preview">{state.lfsPatterns || t("No LFS patterns.")}{"\n"}{state.lfsFiles}</pre>
          <h3>{t("Server locks")}</h3><div className="row"><input className="input grow" placeholder="assets/design.psd" aria-label={t("File to lock")} value={lockPath} onChange={(e) => setLockPath(e.target.value)} /><Button disabled={disabled || !lockPath} onClick={() => task(() => store.lfsLock(lockPath))}>{t("Lock file")}</Button><Button disabled={disabled} onClick={() => task(() => store.loadLfsLocks())}>{t("Load server locks")}</Button></div>
          {state.lfsLocks.map((lock) => <div className="local-entry row" key={lock.id}><span className="grow">{lock.path} · {lock.owner}</span><Button size="small" disabled={disabled} onClick={() => task(() => store.lfsUnlock(lock.id))}>{t("Unlock")}</Button></div>)}
        </>}
      </>}
      {tab === "Submodules" && <>
        <p className="hint">{t("Updates use the exact commit recorded in this repository. Nested submodules and remote branch tips are not updated automatically. Review the server URL before connecting.")}</p>
        {!state.submodules.length && <p className="muted">{t("No submodules.")}</p>}
        {state.submodules.map((entry) => <div className="local-entry" key={entry.path}><div className="row"><b className="grow">{entry.path}</b><code>{entry.status === "-" ? t("Not initialized") : entry.status === "+" ? t("Different commit") : entry.status === "U" ? t("Conflicted") : t("At recorded commit")}</code><Button size="small" disabled={disabled} onClick={() => task(() => store.updateSubmodule(entry))}>{t("Initialize / update")}</Button><Button size="small" disabled={entry.status === "-"} onClick={() => store.openSubmodule(entry.path)}>{t("Open")}</Button></div><small>{store.submoduleURLDisplay(entry.url)} · {entry.sha.slice(0, 12)}</small></div>)}
      </>}
      {tab === "Bisect" && <>
        <p className="hint">{t("Find the first commit that introduced a problem. Test the checked-out commit, then mark the result. Git performs the binary search; no test command runs automatically.")}</p>
        {!state.bisectActive ? <div className="row"><input className="input grow" aria-label={t("Known good commit")} placeholder={t("Known good commit")} value={good} onChange={(e) => setGood(e.target.value)} /><input className="input grow" aria-label={t("Known bad commit")} placeholder={t("Known bad commit")} value={bad} onChange={(e) => setBad(e.target.value)} /><Button disabled={disabled || !good.trim() || !bad.trim()} onClick={() => task(() => store.startBisect(good, bad))}>{t("Start bisect")}</Button></div> : <><p><b>{state.bisectResult ? t("First bad commit found") : t("Test this commit")}</b> · <code>{state.bisectResult || state.bisectCurrent}</code></p><div className="row"><Button disabled={disabled || !!state.bisectResult} onClick={() => task(() => store.markBisect("good"))}>{t("Good")}</Button><Button disabled={disabled || !!state.bisectResult} onClick={() => task(() => store.markBisect("bad"))}>{t("Bad")}</Button><Button disabled={disabled || !!state.bisectResult} onClick={() => task(() => store.markBisect("skip"))}>{t("Skip")}</Button><span className="spacer" /><Button disabled={disabled} onClick={() => task(() => store.resetBisect())}>{t("Reset bisect")}</Button></div><pre className="local-preview">{state.bisectLog}</pre></>}
      </>}
    </div>
  </Modal>;
}
