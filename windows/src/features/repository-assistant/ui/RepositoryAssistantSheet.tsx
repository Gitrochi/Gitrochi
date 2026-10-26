import { useEffect, useState } from "react";
import { ai, repositoryReadRuntime } from "@/entities/ai";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { describe } from "@/shared/platform";
import { Button, Modal, Spinner } from "@/shared/ui";
import { AssistantPresentation } from "./AssistantPresentation";

export function RepositoryAssistantSheet({ store, close, embedded = false }: { store: RepoStore; close: () => void; embedded?: boolean }) {
  useObserve(store);
  useEffect(() => () => store.cancelRepositoryAssistant(), [store]);
  const session = store.repositoryAssistant;
  const finish = () => { store.cancelRepositoryAssistant(); close(); };
  const problem = session ? ai.problem(session.provider) : null;
  return <AssistantPresentation embedded={embedded} title={t("Repository assistant")} width={900} onClose={finish} footer={<>
    <Button disabled={session?.working || session?.loading} onClick={() => void store.openRepositoryAssistant(true, !embedded)}>{t("New conversation")}</Button>
    <span className="spacer" />
    {session?.working && <><Spinner size={14} /><Button onClick={() => store.stopRepositoryAssistant()}>{t("Stop waiting")}</Button></>}
    {!embedded && <Button onClick={finish}>{t("Close")}</Button>}
    <Button kind="primary" disabled={!session?.runtime || session.loading || session.working || !session.question.trim() || session.question.length > 6000 || !!problem}
      onClick={() => void store.sendRepositoryQuestion()}>{t("Send question")}</Button>
  </>}>
    <strong>{session?.providerTitle}</strong>
    <span className="hint">{t("Sending a question lets AI read tracked files, status and history in this repository. Each read is shown below. Files are never changed.")}</span>
    <span className="hint mono">{session?.repository} · HEAD {session?.head?.slice(0, 12) ?? t("No commits")}</span>
    {session?.loading && <span className="row"><Spinner />{t("Preparing repository context…")}</span>}
    {!!session?.preview.length && <details open={!session.messages.length}><summary>{t("Context for AI")}</summary><pre className="mono" style={{ maxHeight: 180, overflow: "auto", whiteSpace: "pre-wrap", userSelect: "text" }}>{session.preview.map((item) => `${item.tool}\n${item.text}${item.truncated ? "\n[truncated]" : ""}`).join("\n\n")}</pre></details>}
    {!!session?.messages.length && <div role="log" aria-label={t("AI conversation")} className="col" style={{ maxHeight: 270, overflow: "auto", gap: 12 }}>
      {session.messages.map((message, i) => <div key={i} className="col" style={{ gap: 4 }}><strong className="hint">{message.role === "user" ? t("You") : t("AI answer")}</strong><div style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere", userSelect: "text" }}>{message.text}</div></div>)}
    </div>}
    {!!session?.traces.length && <details><summary>{t("Read activity")} ({session.traces.length})</summary><div style={{ maxHeight: 210, overflow: "auto" }}>{session.traces.map((trace, i) => <details key={i} style={{ padding: 4 }}><summary className="mono">{trace.request.name} {JSON.stringify(trace.request.arguments)}</summary><pre style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere", userSelect: "text" }}>{trace.error ?? trace.result?.text ?? t("Reading…")}</pre></details>)}</div></details>}
    <textarea className="textarea" rows={3} aria-label={t("Question about this repository")} placeholder={t("Question about this repository")} value={session?.question ?? ""}
      onChange={(event) => { if (session) { session.question = event.target.value; store.changed(); } }}
      onKeyDown={(event) => { if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); void store.sendRepositoryQuestion(); } }} />
    <span className="hint">{t("Reads are bounded and reflect the files at the time they are read. Secret paths, binary files and symlinks are excluded.")}</span>
    {(session?.error || problem) && <div role="alert" style={{ color: "var(--red)", whiteSpace: "pre-wrap", userSelect: "text" }}>{session?.error || problem}</div>}
  </AssistantPresentation>;
}

export function MCPConnectionSheet({ store, close }: { store: RepoStore; close: () => void }) {
  const [config, setConfig] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState("");
  const [working, setWorking] = useState(false);
  const repository = store.path;
  useEffect(() => {
    let active = true;
    if (repository) void repositoryReadRuntime(repository).then((runtime) => {
      if (active) setConfig(JSON.stringify({ mcpServers: { gitrochi: { command: runtime.command, args: runtime.args } } }, null, 2));
    }).catch((e: unknown) => { if (active) setError(describe(e)); });
    return () => { active = false; };
  }, [repository]);
  const test = async () => {
    if (!repository) return;
    setWorking(true); setError(null);
    try {
      const runtime = await repositoryReadRuntime(repository);
      const result = await runtime.call({ name: "git_status", arguments: {} });
      if (store.path === repository) setNotice(t("Read-only connection works.") + "\n" + result.text);
    } catch (e) { if (store.path === repository) setError(describe(e)); }
    finally { setWorking(false); }
  };
  return <Modal title={t("Connect external AI with MCP")} width={850} onClose={close} footer={<><Button disabled={!config || working} onClick={() => void test()}>{t("Test connection")}</Button><span className="spacer" /><Button onClick={close}>{t("Close")}</Button><Button kind="primary" disabled={!config} onClick={() => void navigator.clipboard.writeText(config).then(() => setNotice(t("Copied"))).catch((e: unknown) => setError(describe(e)))}>{t("Copy configuration")}</Button></>}>
    <span>{t("Copy this entry into your AI client's MCP settings. Only this repository is exposed, using read-only local tools.")}</span>
    <span className="hint">{t("Requires Node.js 22 or later and Git. No server, account changes or network listener is created.")}</span>
    <pre className="mono" style={{ maxHeight: 350, overflow: "auto", whiteSpace: "pre-wrap", userSelect: "text" }}>{config}</pre>
    {notice && <pre style={{ whiteSpace: "pre-wrap", maxHeight: 120, overflow: "auto" }}>{notice}</pre>}
    {error && <span role="alert" style={{ color: "var(--red)" }}>{error}</span>}
  </Modal>;
}
