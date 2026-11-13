import { TriangleAlert } from "lucide-react";
import type { ReactNode } from "react";
import { accountHost, type HostAccount, providerInfo } from "@/entities/git";
import { type AccountStatus, accountReason, accountReasonText, accounts, accountStatusAction, accountStatusCaption, accountStatusIcon, accountStatusTitle } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { AccountAvatar, AccountStatusLabel } from "@/features/account-connection";
import { designIcon, Inbox, KeyRound, Lock, Plus, ShieldLock } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { Button, type MenuItem, NoticeBlock, showContextMenu, showMenuBelow } from "@/shared/ui";

const SignedOut = designIcon("account");
const Identity = designIcon("identity");
const People = designIcon("people");

/** What the popover asks its owner to do; the owner closes the popover and opens the sheet or page */
export type AccountPopoverActions = {
  /** Settle an account's state: renew it, approve it or sign in again */
  resolve: (account: HostAccount, status: AccountStatus) => void;
  inbox: () => void;
  addAccount: () => void;
  manageAccounts: () => void;
};

/**
 * The account button's popover, as the Accounts board draws it (docs/design.md, App shell): this repository's account
 * with the reason it was chosen and Change…, the Git identity commits use, the other accounts, then Inbox,
 * Add account… and Manage accounts…. (macOS: AccountPopover)
 */
export function AccountPopover({ store, actions }: { store: RepoStore; actions: AccountPopoverActions }) {
  const all = accounts.accounts;
  const account = store.hostingAccount;
  const target = store.target;
  const candidates = target ? accounts.candidates(target) : [];
  const others = all.filter((item) => item.id !== account?.id);
  /** The board has no button for it, so reading the Git account and its rules again sits in the menus */
  const refresh: MenuItem | null = store.gitchStatus ? { label: t("Refresh account status"), disabled: store.gitchChecking, onClick: () => void store.refreshGitch() } : null;

  const change = (button: HTMLElement) => {
    const items: MenuItem[] = candidates.map((item) => ({ label: `@${item.username} · ${accountHost(item)}`, checked: item.id === account?.id, onClick: () => store.useAccount(item) }));
    showMenuBelow(button, [...items, ...(items.length ? ["divider" as const] : []), { label: t("Add account…"), onClick: actions.addAccount }, ...(refresh ? [refresh] : [])]);
  };
  const identity = store.path ? <IdentityRow store={store} menu={refresh ? [refresh] : []} /> : null;

  if (!all.length) return <>
    {identity && <><div className="account-popover-heading">{t("This repository")}</div>{identity}<div className="account-popover-divider" role="separator" /></>}
    <div className="account-popover-empty">
      <SignedOut size={24} strokeWidth={1.3} />
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
        <AccountRow account={account} own caption={accountReasonText(accountReason(account, target, candidates, accounts.preferredID(store.path)))} resolve={actions.resolve}
          trailing={<Button className="account-popover-change" aria-haspopup="menu" onClick={(event) => change(event.currentTarget)}>{t("Change…")}</Button>} />
      ) : target && (
        <div className="account-popover-row own">
          <span className="account-popover-glyph"><SignedOut size={16} /></span>
          <span className="account-popover-text"><span className="account-popover-title">{t("No account")}</span><span className="account-popover-caption">{t("Connect an account on {0} to use repository services.", target.host)}</span></span>
        </div>
      )}
      {identity}
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
    <button type="button" className="account-popover-action" onClick={actions.manageAccounts}><People size={14} />{t("Manage accounts…")}</button>
  </>;
}

/** This repository's own account needs the user: the notice on top, its one filled action under the words */
function AttentionNotice({ account, resolve }: { account: HostAccount; resolve: (account: HostAccount, status: AccountStatus) => void }) {
  const status = accounts.status(account), action = accountStatusAction(status), icon = accountStatusIcon(status);
  if (!action) return null;
  return (
    <NoticeBlock className="account-popover-notice" stacked icon={icon === "shield" ? <ShieldLock size={14} /> : icon === "key" ? <KeyRound size={14} /> : <TriangleAlert size={14} />}
      title={status === "needsYourApproval" ? t("Saved sign-in needs your approval") : accountStatusTitle(status)} caption={accountStatusCaption(status)}
      actions={[{ label: action, filled: true, onClick: () => resolve(account, status) }]} />
  );
}

/**
 * One account: its photo, "@name · host", and on the second line the caption (why it was chosen, or that it is signed
 * in) or the state it is in. The repository's own row is 52 px with a 32 px photo and a semibold name, and leaves its
 * action to the notice above; the others are 44 px with a 24 px photo and carry their action.
 */
function AccountRow({ account, own = false, caption, trailing, resolve }: {
  account: HostAccount;
  own?: boolean;
  caption?: string;
  trailing?: ReactNode;
  resolve: (account: HostAccount, status: AccountStatus) => void;
}) {
  const status = accounts.status(account), action = accountStatusAction(status), host = accountHost(account);
  const service = account.provider === "gitlab" ? t("Self-hosted GitLab") : providerInfo[account.provider].title;
  return (
    <div className={`account-popover-row ${own ? "own" : ""}`} data-account={account.id}>
      <AccountAvatar account={account} size={own ? 32 : 24} />
      <span className="account-popover-text">
        <span className="account-popover-title"><span className="account-popover-name">@{account.username}</span><span className="account-popover-host">· {host}</span></span>
        {status === "signedIn"
          ? <span className="account-popover-caption">{caption ?? `${t("Signed in")} · ${service}`}</span>
          : <span className="account-popover-caption"><AccountStatusLabel status={status} /></span>}
      </span>
      {action && !own && <Button className="account-popover-resolve" aria-label={`${action} @${account.username}`} onClick={() => resolve(account, status)}>{action}</Button>}
      {trailing}
    </div>
  );
}

/** The author commits in this repository carry; a lock beside the name and on the second line when the rules fix it */
function IdentityRow({ store, menu }: { store: RepoStore; menu: MenuItem[] }) {
  const identity = store.me, locked = !!store.gitchStatus?.lockedAccount;
  return (
    <div className="account-popover-row identity" onContextMenu={menu.length ? (event) => showContextMenu(event, menu) : undefined}>
      <span className="account-popover-glyph"><Identity size={16} strokeWidth={1.4} /></span>
      <span className="account-popover-text">
        <span className="account-popover-title selectable">
          {identity?.name || identity?.email ? <><span>{identity.name}</span>{identity.email && <span className="account-popover-email">&lt;{identity.email}&gt;</span>}</> : t("Not configured")}
          {locked && <Lock className="account-popover-lock" size={12} strokeWidth={1.6} />}
        </span>
        {locked
          ? <span className="account-popover-caption locked" data-status="locked"><Lock size={12} />{t("Locked by this repository's rules")}</span>
          : store.gitchStatus && <span className="account-popover-caption">{t("Author and SSH follow this repository's rules")}</span>}
      </span>
    </div>
  );
}
