import { useLayoutEffect, useRef, useState } from "react";
import { GitBranch, GitPullRequest, Link2, RefreshCw } from "lucide-react";
import { issueTaskReference, projectIssueBranches, workStateTitle, type InboxItem, type IssueLinkedRequest } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";

/** Issues keep the local branch handoff alongside server-reported request links. */
export function IssueDevelopment({ store, item }: { store: RepoStore; item: InboxItem }) {
  const task = issueTaskReference(store.target, item);
  const [requests, setRequests] = useState<IssueLinkedRequest[]>([]), [page, setPage] = useState(0), [more, setMore] = useState(false), [loading, setLoading] = useState(false), [error, setError] = useState<string | null>(null);
  const context = JSON.stringify([store.path, store.target?.provider, store.target?.host, store.target?.path, store.hostingAccount?.id, item.id]), current = useRef(context); current.current = context;
  useLayoutEffect(() => { setRequests([]); setPage(0); setMore(false); setLoading(false); setError(null); }, [context]);
  if (!task) return null;
  const branches = store.path ? projectIssueBranches(store.path, task).filter(name => store.localBranches.some(branch => branch.name === name)) : [];
  const load = async (append = false) => {
    if (loading) return;
    const stamp = context; setLoading(true); setError(null);
    try {
      const result = await store.issueLinkedRequests(item, append ? page + 1 : 1);
      if (current.current !== stamp) return;
      setRequests(old => append ? [...old, ...result.items.filter(next => !old.some(value => value.id === next.id))] : result.items); setMore(result.more); setPage(append ? page + 1 : 1);
    } catch (failure) { if (current.current === stamp) setError(failure instanceof Error ? failure.message : String(failure)); }
    finally { if (current.current === stamp) setLoading(false); }
  };
  return <section className="issue-development" aria-label={t("Development")}>
    <div className="issue-section-heading"><span><GitBranch size={14}/>{t("Development")}</span><Button size="small" tip={t("Refresh linked requests")} aria-label={t("Refresh linked requests")} disabled={loading} onClick={() => void load()}><RefreshCw size={12}/></Button></div>
    <div className="issue-workflow-actions"><Button disabled={!!store.busy || !store.headHash} onClick={() => store.requestIssueBranch(item)}><GitBranch size={13}/>{t("Create branch")}</Button><Button disabled={!!store.busy || !store.headBranch} onClick={() => store.requestIssuePullRequest(item)}><GitPullRequest size={13}/>{t(store.target?.provider === "gitlab" ? "Create merge request" : "Create pull request")}</Button></div>
    <p className="hint">{t("Keep the issue linked from branch to pull request.")}</p>
    {branches.map(name => <button className="issue-branch-chip" key={name} disabled={!!store.busy || store.headBranch === name} onClick={() => { const branch = store.localBranches.find(value => value.name === name); if (branch) void store.checkout(branch); }}><GitBranch size={12}/>{name}{store.headBranch === name && <span>{t("Current")}</span>}</button>)}
    {requests.map(request => <button className="issue-request-link" key={request.id} onClick={() => store.openUrl(request.url)}><GitPullRequest size={14}/><span><strong>#{request.number} {request.title}</strong><small>{workStateTitle(request.state)}</small></span><Link2 size={12}/></button>)}
    {error && <p className="error-text" role="alert">{error}</p>}
    {!page && <Button size="small" disabled={loading} onClick={() => void load()}>{t(loading ? "Loading…" : "Load linked requests")}</Button>}
    {page > 0 && !requests.length && <p className="hint">{t("No linked requests on loaded pages.")}</p>}
    {more && <Button size="small" disabled={loading} onClick={() => void load(true)}>{t("Load more linked requests")}</Button>}
  </section>;
}
