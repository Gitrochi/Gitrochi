import { useEffect, useState } from "react";
import { runBaseRef } from "@/entities/ci";
import { branchShort } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { ArrowUp } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { git } from "@/shared/platform";
import { Button, HostedListSummary } from "@/shared/ui";
import { branchSummary, type BranchSummary } from "@/widgets/inspector";

/**
 * "This branch compared with the server", as the Summary card states board draws it: the branch, how far it is from
 * its base and from the server, and the one next step. Read from local refs; a branch that is its own base has none.
 * (macOS: PullRequestSummary.swift)
 */
export function PullRequestSummary({ store }: { store: RepoStore }) {
  useObserve(store);
  const target = store.target, head = store.headBranch;
  const request = store.pullRequests.find((value) => value.source === head && !value.fromFork);
  const base = request?.target ?? runBaseRef([...store.localBranches.map((branch) => branch.name), ...store.remoteBranches.map(branchShort)]);
  const remoteBase = target && base ? `${target.remote}/${base}` : null;
  const [counts, setCounts] = useState<{ incoming: number; commits: number } | null>(null);
  useEffect(() => {
    let current = true;
    setCounts(null);
    if (!store.path || !remoteBase || head === base) return;
    // both counts come from one local read; a base that was never fetched leaves the card out
    void git(["rev-list", "--left-right", "--count", `${remoteBase}...HEAD`], store.path).then((result) => {
      const parts = result.stdout.trim().split(/\s+/).map(Number);
      if (current && parts.length === 2 && parts.every(Number.isFinite)) setCounts({ incoming: parts[0], commits: parts[1] });
    }).catch(() => {});
    return () => { current = false; };
  }, [store, store.path, head, store.headHash, remoteBase, base]);
  // before the list is read, "no request yet" would be a guess
  if (!target || !head || !base || !remoteBase || head === base || !counts || store.prState.kind !== "loaded") return null;
  const gitlab = target.provider === "gitlab";
  const state = branchSummary(!!request, store.status.ahead, counts.incoming, counts.commits);
  const server = t(gitlab ? "on GitLab" : "on GitHub");
  const headline = state.kind === "noRequest" ? (store.status.upstream ? t("Based on {0}", base) : t("Not on the server yet")) : t(gitlab ? "Merge request open" : "Pull request open");
  const commits = (count: number) => t("{0} commits", count);
  const sha = (store.headHash ?? "").slice(0, 7);
  const action = state.kind === "noRequest" ? <Button onClick={() => store.openSheet({ kind: "createPullRequest" })}>{t(gitlab ? "Create merge request…" : "Create pull request…")}</Button>
    : state.kind === "moved" ? <Button onClick={() => store.merge(remoteBase)}>{t("Update branch")}</Button>
    : state.kind === "notPushed" ? <Button onClick={() => void store.push()}><ArrowUp size={14} />{state.local === 1 ? t("Push 1 commit") : t("Push {0} commits", state.local)}</Button>
    : null;
  return (
    <HostedListSummary
      label={t("This branch compared with the server")}
      lead={<>
        <span className="hosted-summary-key">{t("This branch")}</span>
        <span className="hosted-summary-value pr-summary-branch"><bdi>{head}</bdi></span>
        <span className="hosted-caption">{headline}</span>
      </>}
      middle={<div className="pr-track" role="img" aria-label={headline}>{track(state, base, remoteBase, counts.incoming, target.remote, server, sha, commits)}</div>}
      trail={<>
        {action}
        {state.kind === "moved" && <span className="hosted-caption">{t("Merges {0} into this branch", remoteBase)}</span>}
        {state.kind === "upToDate" && <span className="hosted-caption">{t("Nothing to push")}</span>}
        {state.kind === "notPushed" && request && <span className="hosted-caption">{t(gitlab ? "Updates merge request #{0}" : "Updates pull request #{0}", String(request.number))}</span>}
      </>}
      strip={<>
        <span className="hosted-strip-text pr-summary-branch"><bdi>{head}</bdi></span>
        <span className="hosted-caption">{headline}</span>
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
