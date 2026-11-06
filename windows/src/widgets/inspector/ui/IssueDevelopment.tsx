import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { GitBranch, GitPullRequest } from "lucide-react";
import { issueTaskReference, workStateTitle, type InboxItem, type IssueLinkedRequest } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button, HostedListTextButton } from "@/shared/ui";

type Marker = "done" | "current" | "next" | "closed";

/**
 * The issue's way from opened to closed, as the Issues board's Development card draws it: its linked local branches,
 * the requests they opened and those the server reports, with the next step as a button where the line stops.
 * (macOS: IssueDevelopmentPanel)
 */
export function IssueDevelopment({ store, item }: { store: RepoStore; item: InboxItem }) {
  const task = issueTaskReference(store.target, item);
  const [requests, setRequests] = useState<IssueLinkedRequest[]>([]), [page, setPage] = useState(0), [more, setMore] = useState(false), [loading, setLoading] = useState(false), [error, setError] = useState<string | null>(null);
  const context = JSON.stringify([store.path, store.target?.provider, store.target?.host, store.target?.path, store.hostingAccount?.id, item.id]), current = useRef(context); current.current = context;
  useLayoutEffect(() => { setRequests([]); setPage(0); setMore(false); setLoading(false); setError(null); }, [context]);
  if (!task) return null;
  const branches = store.issueBranches(item);
  // a request one of the branches opened is known without asking the server
  const local = store.pullRequests.filter((request) => branches.includes(request.source));
  const linked = requests.filter((request) => !local.some((value) => value.number === request.number));
  const open = ["open", "opened"].includes(item.state), gitlab = store.target?.provider === "gitlab";
  const createRequest = t(gitlab ? "Create merge request" : "Create pull request");
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
  return <section className="issue-card issue-development" aria-label={t("Development")}>
    <span className="issue-card-title">{t("Development")}</span>
    <div className="issue-steps">
      <Step marker="done"><span>{t("Opened")}</span></Step>
      {branches.map(name => {
        const branch = store.localBranches.find(value => value.name === name);
        const notes = [name === store.headBranch ? t("Current") : "", branch && !branch.upstream ? t("Not on the server yet") : branch && branch.ahead > 0 ? t("{0} not pushed", branch.ahead) : ""].filter(Boolean);
        // a click checks the branch out; the caption says whether it is the current one and what is not pushed
        return <Step key={name} marker="done"><button className="issue-step-link issue-branch" data-tip={t("Check out branch")} disabled={!!store.busy || store.headBranch === name} onClick={() => { if (branch) void store.checkout(branch); }}><strong className="ellipsis">{name}</strong></button>{notes.length > 0 && <span className="hosted-caption">{notes.join(" · ")}</span>}</Step>;
      })}
      {!branches.length && <Step marker="next"><Button disabled={!!store.busy || !store.headHash} onClick={() => store.requestIssueBranch(item)}><GitBranch size={14}/>{t("Create branch")}</Button></Step>}
      {local.map(request => <Step key={request.number} marker="current"><button className="issue-step-link" onClick={() => store.openIssueRequest(request)}><span>{request.title} <span className="mono hosted-caption">#{request.number}</span></span><span className="hosted-caption">{request.isDraft ? t("Draft") : workStateTitle("open")}</span></button></Step>)}
      {linked.map(request => <Step key={request.id} marker={["open", "opened"].includes(request.state) ? "current" : "done"}><button className="issue-step-link" onClick={() => store.openUrl(request.url)}><span>{request.title} <span className="mono hosted-caption">#{request.number}</span></span><span className="hosted-caption">{workStateTitle(request.state)}</span></button></Step>)}
      {branches.length > 0 && !local.length && !linked.length && <Step marker="next"><Button disabled={!!store.busy || !store.headBranch} onClick={() => store.requestIssuePullRequest(item)}><GitPullRequest size={14}/>{createRequest}</Button></Step>}
      <Step marker={open ? "next" : "closed"} last><span>{workStateTitle("closed")}</span>{open && (local.length > 0 || linked.length > 0) && <span className="hosted-caption">{t(gitlab ? "When the merge request merges" : "When the pull request merges")}</span>}</Step>
    </div>
    {error && <p className="error-text" role="alert">{error}</p>}
    {page > 0 && !requests.length && <span className="hosted-caption">{t("No linked requests on loaded pages.")}</span>}
    {/* what the server knows is read only when asked for */}
    <div className="issue-card-actions">
      {!page ? <HostedListTextButton disabled={loading} onClick={() => void load()}>{t(loading ? "Loading…" : "Load linked requests")}</HostedListTextButton>
        : <HostedListTextButton disabled={loading} onClick={() => void load()}>{t("Refresh linked requests")}</HostedListTextButton>}
      {more && <HostedListTextButton disabled={loading} onClick={() => void load(true)}>{t("Load more linked requests")}</HostedListTextButton>}
      {branches.length > 0 && <HostedListTextButton disabled={!!store.busy || !store.headHash} onClick={() => store.requestIssueBranch(item)}>{t("Create branch")}</HostedListTextButton>}
      {(local.length > 0 || linked.length > 0 || !branches.length) && <HostedListTextButton disabled={!!store.busy || !store.headBranch} onClick={() => store.requestIssuePullRequest(item)}>{createRequest}</HostedListTextButton>}
    </div>
  </section>;
}

/** One step of the line: its marker with the line down to the next step, and its content beside them */
function Step({ marker, last = false, children }: { marker: Marker; last?: boolean; children: ReactNode }) {
  return <>
    <span className="issue-step-rail"><span className={`issue-mark ${marker}`}/>{!last && <span className="issue-step-line"/>}</span>
    <span className={`issue-step${last ? " last" : ""}`}>{children}</span>
  </>;
}
