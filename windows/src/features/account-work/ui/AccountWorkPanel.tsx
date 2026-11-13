import { useEffect, useState, type ReactNode } from "react";
import { AtSign, Bell, PencilLine, TriangleAlert } from "lucide-react";
import { CircleDot, CirclePlay, CircleX, GitMerge, ListChecks } from "@/shared/icons";
import { ArrowUpDown, Check, ExternalLink, Eye, GitPullRequest, Inbox, Search, User } from "@/shared/icons";
import { gitAccountAvatarURL } from "@/entities/gitch";
import { accountHost, type HostAccount } from "@/entities/git";
import { accounts, workStateTitle, type AccountWorkItem, type AccountWorkKind } from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { language, t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Avatar, Button, FailureBlock, Segmented, showContextMenu, showMenuBelow, Spinner, StatusPill, type StatusTone } from "@/shared/ui";
import { inboxReason, inboxReasonLabel, isLocalWork, repositoryName, visibleWork, workGroups, workReference, workWhen, type InboxReason } from "../lib/account-inbox";
import type { AccountWorkFailure, AccountWorkModel } from "../model/account-work-model";
import "./account-work.css";

const reasonLook: Record<InboxReason, { icon: ReactNode; tone: StatusTone }> = {
  review: { icon: <Eye />, tone: "info" },
  mention: { icon: <AtSign />, tone: "info" },
  assigned: { icon: <User />, tone: "info" },
  ciFailed: { icon: <CircleX />, tone: "failed" },
  ci: { icon: <CirclePlay />, tone: "neutral" },
  update: { icon: <Bell />, tone: "neutral" },
};
const categories: [Exclude<AccountWorkKind, "inbox">, string][] = [
  ["mine", "Authored requests"],
  ["assignedRequests", "Assigned requests"],
  ["review", "Review requested"],
  ["issues", "Assigned issues"],
  ["myIssues", "Authored issues"],
];

/**
 * docs/design.md, Controls: an empty or blocked state is a 24 px grey icon, one 15 px semibold line, one 12 px caption
 * and one action, filled only when the state blocks the user. (macOS: AccountState)
 */
export function AccountState({ icon, title, caption, action, filled = false, onAction }: { icon: ReactNode; title: string; caption?: string; action?: string; filled?: boolean; onAction?: () => void }) {
  return (
    <div className="account-state">
      <span className="account-state-icon" aria-hidden>{icon}</span>
      <span className="account-state-title">{title}</span>
      {caption && <span className="account-state-caption">{caption}</span>}
      {action && <Button kind={filled ? "primary" : "default"} onClick={onAction}>{action}</Button>}
    </div>
  );
}

/** The one form of an expired sign-in: a warning icon, the account it concerns and the way to sign in again */
export function SignInExpired({ account, openSettings }: { account: HostAccount; openSettings: () => void }) {
  return (
    <AccountState icon={<span className="status-tone account-state-tone" data-tone="waiting"><TriangleAlert size={24} /></span>} title={t("Sign-in expired")}
      caption={t("@{0} on {1}. Local branches and commits still work.", account.username, accountHost(account))} action={t("Sign in again…")} filled onAction={openSettings} />
  );
}

/**
 * A list column with search, sort and one filter, and the selected row beside it, as the Account board draws the
 * inbox. The open repository's own requests and issues open on their page of the app. (macOS: AccountWorkPanel)
 */
export function AccountWorkPanel({ model, account, target, onOpen, openSettings }: {
  model: AccountWorkModel;
  account: HostAccount;
  target: { host: string; path: string } | null;
  onOpen: (item: AccountWorkItem) => void;
  openSettings: () => void;
}) {
  useObserve(model);
  useObserve(accounts);
  const [search, setSearch] = useState("");
  const [unreadOnly, setUnreadOnly] = useState(false);
  const [oldestFirst, setOldestFirst] = useState(false);
  const key = JSON.stringify([account.id, model.kind, accounts.revision]);
  useEffect(() => {
    model.open(key);
    void model.load(account);
    return () => model.cancel();
  }, [model, key]);

  const host = accountHost(account), now = Date.now() / 1000;
  const title = (failure: AccountWorkFailure) => (failure.kind === "message" ? failure.text : t("Couldn't reach {0}", host));
  const reload = () => void model.load(account);
  if (model.failure?.kind === "expired") return <SignInExpired account={account} openSettings={openSettings} />;
  // nothing to keep on screen, so the failure takes the place of the rows; recovering is a plain button
  const failed = !model.items.length && model.failure
    ? <AccountState icon={<span className="status-tone account-state-tone" data-tone="failed"><CircleX size={24} /></span>} title={title(model.failure)} action={t("Retry")} onAction={reload} />
    : null;
  // My work keeps its list column, so another category can be chosen when one of them fails
  if (failed && model.inbox) return failed;

  const rows = visibleWork(model.items, search, model.inbox && unreadOnly, oldestFirst);
  // the first row shows until another is chosen, as on the board
  const selected = rows.find((item) => item.id === model.selectedID) ?? rows[0];
  const groups = workGroups(rows, now), words = search.trim();
  const unread = model.items.filter((item) => item.unread).length;

  const trailing = (item: AccountWorkItem) => {
    // the inbox says why the row is there; My work says a draft, and whose it is when it is not the account's own
    if (model.inbox) {
      const reason = inboxReason(item), look = reasonLook[reason];
      return <StatusPill tone={look.tone} icon={look.icon}>{inboxReasonLabel(reason, item.actor)}</StatusPill>;
    }
    if (item.status === "draft") return <StatusPill tone="waiting" icon={<PencilLine />}>{t("Draft")}</StatusPill>;
    return item.author && item.author.toLowerCase() !== account.username.toLowerCase() ? <span className="account-row-author">@{item.author}</span> : null;
  };
  const row = (item: AccountWorkItem) => {
    const on = item.id === selected?.id, reference = workReference(item);
    return (
      // keyboard focus moves the selection: the focused row gets the tint, not a ring
      <button key={item.id} type="button" className={`account-row${on ? " selected" : ""}${item.unread ? " unread" : ""}${model.inbox ? " with-dot" : ""}`} aria-current={on ? "true" : undefined}
        onClick={() => model.select(item.id)} onFocus={() => model.select(item.id)}
        onContextMenu={(event) => showContextMenu(event, [
          { label: t("Open in browser"), onClick: () => void ipc.openUrl(item.url) },
          ...(item.unread && item.readID ? [{ label: t("Mark as read"), disabled: model.busy, onClick: () => void model.read(item, account) }] : []),
        ])}>
        {model.inbox && <span className="account-dot" role="img" aria-label={t(item.unread ? "Unread" : "Read")} />}
        <span className="account-row-text">
          <span className="account-row-top">
            <span className="account-row-title">{item.title}</span>
            {item.updated !== null && <span className="account-row-when">{workWhen(item.updated, now, language)}</span>}
          </span>
          <span className="account-row-meta">
            {reference && <><span className="account-row-ref">{reference}</span><span aria-hidden>·</span></>}
            <span className="account-row-repo ellipsis">{repositoryName(item.repository)}</span>
            <span className="grow" />
            {trailing(item)}
          </span>
        </span>
      </button>
    );
  };
  const group = (label: string, items: AccountWorkItem[]) => !!items.length && <>
    <span className="account-group" role="heading" aria-level={3}>{t(label)}</span>
    {items.map(row)}
  </>;
  const empty = () => {
    if (model.busy && !model.items.length) return <span className="account-loading"><Spinner size={12} />{t("Loading…")}</span>;
    if (words) return <AccountState icon={<Search size={24} />} title={t(model.inbox ? "No notifications match “{0}”" : "No items match “{0}”", words)} caption={t("The search covers titles, numbers and repositories.")} action={t("Clear search")} onAction={() => setSearch("")} />;
    if (model.inbox && unreadOnly && model.items.length) return <AccountState icon={<Inbox size={24} />} title={t("No unread notifications")} caption={t("Read notifications are under All.")} action={t("Show all")} onAction={() => setUnreadOnly(false)} />;
    if (model.inbox) return <AccountState icon={<Inbox size={24} />} title={t("No notifications")} caption={t("Review requests, mentions and assignments for @{0} appear here.", account.username)} action={t("Refresh")} onAction={reload} />;
    return <AccountState icon={<ListChecks size={24} />} title={t("Nothing open in this list")} caption={t("No open pull requests or issues for @{0} here. Choose another list above.", account.username)} action={t("Refresh")} onAction={reload} />;
  };

  const local = !!selected && isLocalWork(selected, target);
  const state = (item: AccountWorkItem) => {
    const Subject = item.kind === "request" ? GitPullRequest : CircleDot;
    switch (item.status) {
      case "open": return <StatusPill tone="passed" icon={<Subject />}>{workStateTitle("open")}</StatusPill>;
      case "draft": return <StatusPill tone="waiting" icon={<PencilLine />}>{t("Draft")}</StatusPill>;
      case "merged": return <StatusPill tone="neutral" icon={<GitMerge />}>{workStateTitle("merged")}</StatusPill>;
      case "closed": return <StatusPill tone="neutral" icon={<CircleX />}>{workStateTitle("closed")}</StatusPill>;
      default: return null;
    }
  };
  const who = selected ? selected.actor || selected.author : "";
  const whoAvatar = selected ? (selected.actor ? selected.actorAvatarURL : selected.authorAvatarURL)
    ?? ((selected.provider ?? account?.provider) === "github" ? gitAccountAvatarURL(selected.host, selected.actor ? selected.actorUsername ?? "" : selected.author) : null) : null;

  return (
    <div className="account-work">
      <div className="account-split">
        <aside className="account-list" aria-label={t(model.inbox ? "Inbox" : "My work")}>
          {model.failure && !failed && (
            // a refresh that failed leaves the last rows and says how old they are
            <FailureBlock className="account-notice" title={title(model.failure)} retrying={model.busy} retry={reload}
              caption={model.loadedAt !== null ? t("Showing data from {0}", workWhen(model.loadedAt, now, language)) : null} />
          )}
          <div className="account-list-controls">
            <div className="account-list-search">
              <label className="account-search">
                <Search size={13} />
                <input aria-label={t(model.inbox ? "Search notifications" : "Search my work")} placeholder={t(model.inbox ? "Search notifications" : "Search my work")} value={search} onChange={(event) => setSearch(event.target.value)} />
              </label>
              <Button className="account-icon-button" tip={t("Sort")} aria-label={t("Sort")} aria-haspopup="menu"
                onClick={(event) => showMenuBelow(event.currentTarget, [
                  { label: t("Newest first"), checked: !oldestFirst, onClick: () => setOldestFirst(false) },
                  { label: t("Oldest first"), checked: oldestFirst, onClick: () => setOldestFirst(true) },
                ])}><ArrowUpDown size={14} /></Button>
            </div>
            {model.inbox
              ? <Segmented stretch value={unreadOnly ? "unread" : "all"} onChange={(value) => setUnreadOnly(value === "unread")}
                  options={[{ value: "unread", label: t("Unread {0}", unread) }, { value: "all", label: t("All {0}", model.items.length) }]} />
              : <select className="select" aria-label={t("Work category")} value={model.kind} disabled={model.busy} onChange={(event) => model.setKind(event.target.value as Exclude<AccountWorkKind, "inbox">)}>
                  {categories.map(([value, label]) => <option key={value} value={value}>{t(label)}</option>)}
                </select>}
          </div>
          {rows.length ? (
            <div className="account-rows">
              {/* oldest first shows the earlier rows above today's */}
              {oldestFirst ? <>{group("Earlier", groups.earlier)}{group("Today", groups.today)}</> : <>{group("Today", groups.today)}{group("Earlier", groups.earlier)}</>}
              {model.more && <button type="button" className="account-more" disabled={model.busy} onClick={() => void model.load(account, true)}>{t("Load more")}</button>}
            </div>
          ) : failed ?? empty()}
        </aside>
        <main className="account-detail">
          {selected && <>
            <div className="account-detail-head">
              {workReference(selected) && <span className="account-detail-ref">{workReference(selected)}</span>}
              {state(selected)}
            </div>
            <h2 className="selectable">{selected.title}</h2>
            <div className="account-detail-meta">
              {who && <span className="account-detail-who"><Avatar name={who} email={selected.author || who} size={20} url={whoAvatar} /><strong>{selected.actor ? who : `@${who}`}</strong></span>}
              {model.inbox && <span>{inboxReasonLabel(inboxReason(selected))}</span>}
            {/* the row shows the repository's name only; here is where it lives */}
              <span className="selectable">{selected.host}/{selected.repository}</span>
              {selected.source && selected.target && <StatusPill tone="neutral">{selected.source} → {selected.target}</StatusPill>}
            </div>
            {selected.body && <p className="account-detail-body">{selected.body}</p>}
            {/* one filled button: in the app when the open repository owns the item, in the browser otherwise */}
            <div className="account-detail-actions">
              {local && <Button kind="primary" onClick={() => onOpen(selected)}>
                {selected.kind === "request" ? <GitPullRequest size={14} /> : <CircleDot size={14} />}
                {selected.kind === "request" ? t(inboxReason(selected) === "review" ? "Review in Pull requests" : "Open in Pull requests") : t("Open in Issues")}
              </Button>}
              <Button kind={local ? "default" : "primary"} onClick={() => void ipc.openUrl(selected.url)}><ExternalLink size={14} />{t("Open in browser")}</Button>
              {selected.unread && selected.readID && <Button disabled={model.busy} onClick={() => void model.read(selected, account)}><Check size={14} />{t("Mark as read")}</Button>}
            </div>
          </>}
        </main>
      </div>
    </div>
  );
}
