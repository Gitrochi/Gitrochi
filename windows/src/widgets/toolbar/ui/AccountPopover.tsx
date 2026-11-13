import { TriangleAlert } from "lucide-react";
import type { ReactNode } from "react";
import { accountHost, type HostAccount, providerInfo } from "@/entities/git";
import { type AccountStatus, accountReason, accountReasonText, accounts, accountStatusAction, accountStatusCaption, accountStatusIcon, accountStatusTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { AccountAvatar, AccountStatusLabel, LockedLabel } from "@/features/account-connection";
import { designIcon, Inbox, KeyRound, Plus, Settings, ShieldLock, UserRound } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { Button, type MenuItem, NoticeBlock, showMenuBelow } from "@/shared/ui";

const AccountGlyph = designIcon("account");

/** What the popover asks its owner to do; the owner closes the popover and opens the sheet or page */
export type AccountPopoverActions = {
  /** Settle an account's state: renew it, approve it or sign in again */
  resolve: (account: HostAccount, status: AccountStatus) => void;
  inbox: () => void;
  addAccount: () => void;
  manageAccounts: () => void;
};

/**
 * The account button's popover (docs/design.md, App shell): this repository's account with the reason it was chosen
 * and Change…, the Git identity commits use, the other accounts, then Inbox, Add account… and Manage accounts….
 * (macOS: AccountPopover)
 */
export function AccountPopover({ store, actions }: { store: RepoStore; actions: AccountPopoverActions }) {
  const all = accounts.accounts;
  const account = store.hostingAccount;
  const target = store.target;
  const candidates = target ? accounts.candidates(target) : [];
  const others = all.filter((item) => item.id !== account?.id);
  const locked = !!store.gitchStatus?.lockedAccount;

  const change = (button: HTMLElement) => {
    const items: MenuItem[] = candidates.map((item) => ({ label: `@${item.username} · ${accountHost(item)}`, checked: item.id === account?.id, onClick: () => store.useAccount(item) }));
    showMenuBelow(button, [...items, ...(items.length ? ["divider" as const] : []), { label: t("Add account…"), onClick: actions.addAccount }]);
  };

  if (!all.length) return <>
    {store.path && <div className="account-popover-heading">{t("This repository")}</div>}
    {store.path && <IdentityRow store={store} locked={locked} />}
    {store.path && <div className="account-popover-divider" role="separator" />}
    <div className="account-popover-empty">
      <AccountGlyph size={24} strokeWidth={1.3} />
      <strong>{t("No account")}</strong>
      <span>{t("Add a GitHub or GitLab account for pull requests, issues and CI. Commits work without one.")}</span>
      <Button kind="primary" onClick={actions.addAccount}>{t("Add account…")}</Button>
    </div>
  </>;

  return <>
    {store.path ? <>
      {account && <AttentionNotice account={account} resolve={actions.resolve} />}
      <div className="account-popover-heading">{t("This repository")}</div>
      {account && target ? (
        <AccountRow account={account} size={32} ownAction={false} caption={accountReasonText(accountReason(account, target, candidates, accounts.preferredID(store.path)))} resolve={actions.resolve}
          trailing={<Button className="account-popover-change" aria-haspopup="menu" onClick={(event) => change(event.currentTarget)}>{t("Change…")}</Button>} />
      ) : target && (
        <div className="account-popover-row tall">
          <span className="account-popover-glyph large"><UserRound size={16} /></span>
          <span className="account-popover-text"><span className="account-popover-title">{t("No account")}</span><span className="account-popover-caption">{t("Connect an account on {0} to use repository services.", target.host)}</span></span>
        </div>
      )}
      <IdentityRow store={store} locked={locked} />
    </> : <>
      <div className="account-popover-heading">{t("Accounts")}</div>
      <div className="account-popover-hint">{t("Open a repository to see which account it uses.")}</div>
    </>}
    {others.length > 0 && <>
      {store.path && <div className="account-popover-divider" role="separator" />}
      {store.path && <div className="account-popover-heading">{account ? t("Other accounts") : t("Accounts")}</div>}
      {others.map((item) => <AccountRow key={item.id} account={item} resolve={actions.resolve} />)}
    </>}
    <div className="account-popover-divider" role="separator" />
    <button type="button" className="account-popover-action" onClick={actions.inbox}><Inbox size={14} />{t("Inbox")}</button>
    <button type="button" className="account-popover-action" onClick={actions.addAccount}><Plus size={14} />{t("Add account…")}</button>
    <button type="button" className="account-popover-action" onClick={actions.manageAccounts}><Settings size={14} />{t("Manage accounts…")}</button>
  </>;
}

/** This repository's own account needs the user: the shared notice, with the one action that settles it */
function AttentionNotice({ account, resolve }: { account: HostAccount; resolve: (account: HostAccount, status: AccountStatus) => void }) {
  const status = accounts.status(account), action = accountStatusAction(status), icon = accountStatusIcon(status);
  if (!action) return null;
  return (
    <NoticeBlock className="account-popover-notice" icon={icon === "shield" ? <ShieldLock size={14} /> : icon === "key" ? <KeyRound size={14} /> : <TriangleAlert size={14} />}
      title={accountStatusTitle(status)} caption={accountStatusCaption(status)} actions={[{ label: action, onClick: () => resolve(account, status) }]} />
  );
}

/**
 * One account: its photo, "@name · host", and on the second line the caption (why it was chosen, or that it is signed
 * in) or the state it is in with the one action that settles it
 */
function AccountRow({ account, size = 24, caption, ownAction = true, trailing, resolve }: {
  account: HostAccount;
  size?: number;
  caption?: string;
  /** false where a notice above the row already carries the action */
  ownAction?: boolean;
  trailing?: ReactNode;
  resolve: (account: HostAccount, status: AccountStatus) => void;
}) {
  const status = accounts.status(account), action = accountStatusAction(status), host = accountHost(account);
  const service = account.provider === "gitlab" ? t("Self-hosted GitLab") : providerInfo[account.provider].title;
  return (
    <div className={`account-popover-row ${size > 24 ? "tall" : ""}`} data-account={account.id}>
      <AccountAvatar account={account} size={size} />
      <span className="account-popover-text">
        <span className="account-popover-title"><b>@{account.username}</b><span className="account-popover-host">· {host}</span></span>
        {status === "signedIn"
          ? <span className="account-popover-caption">{caption ?? `${t("Signed in")} · ${service}`}</span>
          : <span className="account-popover-caption"><AccountStatusLabel status={status} /></span>}
      </span>
      {action && ownAction && <Button className="account-popover-resolve" aria-label={`${action} @${account.username}`} onClick={() => resolve(account, status)}>{action}</Button>}
      {trailing}
    </div>
  );
}

/** The author commits in this repository carry, and whether the repository's rules fix it */
function IdentityRow({ store, locked }: { store: RepoStore; locked: boolean }) {
  const identity = store.me;
  return (
    <div className="account-popover-row identity">
      <span className="account-popover-glyph large"><UserRound size={16} /></span>
      <span className="account-popover-text">
        <span className="account-popover-title selectable">
          {identity?.name || identity?.email ? <><span>{identity.name}</span>{identity.email && <span className="account-popover-email">&lt;{identity.email}&gt;</span>}</> : t("Not configured")}
        </span>
        {locked
          ? <span className="account-popover-caption"><LockedLabel text={t("Locked by this repository's rules")} /></span>
          : store.gitchStatus && <span className="account-popover-caption">{t("Author and SSH follow this repository's rules")}</span>}
      </span>
    </div>
  );
}
