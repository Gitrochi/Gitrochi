import { useEffect, useRef, useState } from "react";
import { runBaseRef } from "@/entities/ci";
import { branchShort } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { ArrowUp } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { git } from "@/shared/platform";
import { Button, HostedListSummary, HostedListSummaryBar, HostedListSummaryBars, HostedListSummaryLoadingLine, HostedListSummaryMessage, Spinner } from "@/shared/ui";
import { type BranchCounts, type BranchSummary, type RequestListRead, requestSummaryCard } from "@/widgets/inspector";

/**
 * "This branch compared with the server", as the Summary card states board draws it: the branch, how far it is from
 * its base and from the server, and the one next step. Read from local refs. The card is there from the first frame,
 * loading until the list and the counts are read, and says so when the branch has no request to open.
 * (macOS: PullRequestSummary.swift)
 */
export function PullRequestSummary({ store, openSettings }: { store: RepoStore; openSettings: () => void }) {
  useObserve(store);
  const target = store.target, head = store.headBranch;
  const request = store.pullRequests.find((value) => value.source === head && !value.fromFork);
  const base = request?.target ?? runBaseRef([...store.localBranches.map((branch) => branch.name), ...store.remoteBranches.map(branchShort)]);
  const remoteBase = target && base ? `${target.remote}/${base}` : null;
  const countsKey = `${store.path ?? ""}|${head ?? ""}|${remoteBase ?? ""}`;
  const [counts, setCounts] = useState<{ key: string; value: BranchCounts } | null>(null);
  useEffect(() => {
    let current = true;
    const done = (value: BranchCounts) => { if (current) setCounts({ key: countsKey, value }); };
    // a base that was never fetched leaves the card without its track
    if (!store.path || !remoteBase || !head || head === base) { done("unavailable"); return; }
    // both counts come from one local read
    void git(["rev-list", "--left-right", "--count", `${remoteBase}...HEAD`], store.path).then((result) => {
      const parts = result.stdout.trim().split(/\s+/).map(Number);
      done(parts.length === 2 && parts.every(Number.isFinite) ? { incoming: parts[0], commits: parts[1] } : "unavailable");
    }).catch(() => done("unavailable"));
    return () => { current = false; };
  }, [store, store.path, head, store.headHash, remoteBase, base]);
  // the list this view saw read: a refresh, or a failed one, keeps the card as that read left it
  const listKey = `${store.path ?? ""}|${target?.host ?? ""}/${target?.path ?? ""}|${store.hostingAccount?.id ?? ""}`;
  const readKey = useRef<string | null>(null);
  const kind = store.prState.kind;
  if (kind === "loaded") readKey.current = listKey;
  if (!target) return null;
  const list: RequestListRead = kind === "loaded" ? "read" : kind === "needsAccount" ? "noAccount" : readKey.current === listKey ? "read" : kind === "failed" ? "failed" : "pending";
  const read = counts?.key === countsKey ? counts.value : "pending";
  const card = requestSummaryCard(list, head, base, !!request, store.status.ahead, read);
  const gitlab = target.provider === "gitlab";
  const server = t(gitlab ? "on GitLab" : "on GitHub");
  const requestOpen = t(gitlab ? "Merge request open" : "Pull request open");
  const loadingCaption = t(gitlab ? "Loading merge requests…" : "Loading pull requests…");
  const nothingToOpen = t(gitlab ? "No merge request to open from here" : "No pull request to open from here");
  const connect = t(gitlab ? "Connect a GitLab account to see merge requests" : "Connect a GitHub account to see pull requests");
  // what this clone knows of the branch without the server
  const local = !head ? null : !store.status.upstream ? t("Not on the server yet") : base && base !== head ? t("Based on {0}", base) : null;
  const state = card.kind === "branch" ? card.state : null;
  // the line under the branch name
  const line = card.kind === "noAccount" ? local
    : card.kind === "failed" ? t("Couldn't reach {0}", target.host)
    : card.kind === "uncounted" ? (card.hasRequest ? requestOpen : local)
    : state ? (state.kind === "noRequest" ? local : requestOpen)
    : null;
  // the strip says in one line what the card says in its lead and its middle
  const stripLine = card.kind === "loading" ? loadingCaption : card.kind === "noAccount" ? connect : card.kind === "detached" || card.kind === "base" ? nothingToOpen : line;
  const commits = (count: number) => t("{0} commits", count);
  const sha = (store.headHash ?? "").slice(0, 7);
  const create = <Button onClick={() => store.openSheet({ kind: "createPullRequest" })}>{t(gitlab ? "Create merge request…" : "Create pull request…")}</Button>;
  // the one next step, in the trail and at the end of the strip; "no account" blocks the page, so its action is the filled one
  const action = card.kind === "noAccount" ? <Button kind="primary" onClick={openSettings}>{t("Connect account…")}</Button>
    : card.kind === "uncounted" ? (card.hasRequest ? null : create)
    : !state ? null
    : state.kind === "noRequest" ? create
    : state.kind === "moved" ? <Button onClick={() => remoteBase && store.merge(remoteBase)}>{t("Update branch")}</Button>
    : state.kind === "notPushed" ? <Button onClick={() => void store.push()}><ArrowUp size={14} />{state.local === 1 ? t("Push 1 commit") : t("Push {0} commits", state.local)}</Button>
    : null;
  const name = head ?? t("Detached HEAD");
  return (
    <HostedListSummary
      label={t("This branch compared with the server")}
      lead={<>
        <span className="hosted-summary-key">{t("This branch")}</span>
        {/* a branch name is cut from the front, where it says least */}
        <span className="hosted-summary-value pr-summary-branch"><bdi>{name}</bdi></span>
        {card.kind === "loading" ? <HostedListSummaryLoadingLine caption={loadingCaption} /> : line && <span className="hosted-caption ellipsis">{line}</span>}
      </>}
      middle={card.kind === "loading" ? <HostedListSummaryBars />
        : card.kind === "noAccount" ? <HostedListSummaryMessage title={connect} caption={t("{0} is on {1}. Commits and branches work without an account.", target.path, target.host)} />
        : card.kind === "detached" ? <HostedListSummaryMessage title={nothingToOpen} />
        : card.kind === "base" ? <HostedListSummaryMessage title={nothingToOpen} caption={t("{0} is the base branch. Switch to another branch to open one.", base ?? "")} />
        : state && base && remoteBase ? <div className="pr-track" role="img" aria-label={line ?? ""}>{track(state, base, remoteBase, typeof read === "object" ? read.incoming : 0, target.remote, server, sha, commits)}</div>
        : null}
      trail={card.kind === "loading" ? <HostedListSummaryBar /> : <>
        {action}
        {state?.kind === "moved" && <span className="hosted-caption">{t("Merges {0} into this branch", remoteBase ?? "")}</span>}
        {state?.kind === "upToDate" && <span className="hosted-caption">{t("Nothing to push")}</span>}
        {state?.kind === "notPushed" && request && <span className="hosted-caption">{t(gitlab ? "Updates merge request #{0}" : "Updates pull request #{0}", String(request.number))}</span>}
      </>}
      strip={<>
        {card.kind === "loading" && <Spinner size={14} />}
        <span className="hosted-strip-text pr-summary-branch"><bdi>{name}</bdi></span>
        {stripLine && <span className="hosted-caption ellipsis">{stripLine}</span>}
        <span className="spacer" />
        {action}
      </>}
    />
  );
}

function Node({ title, caption, kind = "", warn = false, mono = false }: { title: string; caption: string; kind?: "" | "current" | "strong"; warn?: boolean; mono?: boolean }) {
  return <div className={`pr-track-node ${kind}`}><span className="pr-track-dot" /><strong>{title}</strong><span className={`${mono ? "mono" : ""}${warn ? " status-tone" : ""}`} data-tone="waiting">{caption}</span></div>;
}

const Line = ({ label, dashed = false }: { label: string; dashed?: boolean }) => <div className={`pr-track-line${dashed ? " dashed" : ""}`}><span>{label}</span></div>;

function track(state: BranchSummary, base: string, remoteBase: string, incoming: number, remote: string, server: string, sha: string, commits: (count: number) => string) {
  switch (state.kind) {
    case "noRequest": return <>{incoming > 0 ? <Node title={remoteBase} caption={t("{0} new commits", incoming)} warn /> : <Node title={base} caption={t("base")} />}<Line label={commits(state.commits)} /><Node title="HEAD" caption={sha} kind="current" mono /></>;
    case "moved": return <><Node title={remoteBase} caption={t("{0} new commits", state.incoming)} warn /><Line label={commits(state.commits)} /><Node title={`HEAD = ${remote}`} caption={server} kind="current" /></>;
    case "upToDate": return <><Node title={base} caption={t("base")} /><Line label={commits(state.commits)} /><Node title={`HEAD = ${remote}`} caption={server} kind="current" /></>;
    case "notPushed": return <><Node title={base} caption={t("base")} /><Line label={commits(state.onServer)} /><Node title={remote} caption={server} kind="strong" /><Line label={t("Not pushed")} dashed /><Node title="HEAD" caption={sha} kind="current" mono /></>;
  }
}
