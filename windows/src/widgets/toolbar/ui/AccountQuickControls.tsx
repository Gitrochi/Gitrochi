import { LockKeyhole } from "@/shared/icons";
import { ChevronDown, UserRound, X } from "@/shared/icons";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { AccountConnections, GitchBrowserLogin } from "@/features/account-connection";
import { accountHost, providerInfo } from "@/entities/git";
import { gitAccountKey, type GitHubLoginCapability } from "@/entities/gitch";
import { accounts } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Avatar, Button, SharedSheet } from "@/shared/ui";
import "./account-quick-controls.css";
import { GitAccountAvatar } from "./GitAccountAvatar";

type AccountSheet = { kind: "connections" } | { kind: "login"; expectedLogin?: string; capability: GitHubLoginCapability };

/** 저장소 서비스 계정은 고를 수 있고 Git 잠금·작성자 정보는 저장소 규칙 그대로 보여 준다. */
export function AccountQuickControls({ store }: { store: RepoStore }) {
  useObserve(store); useObserve(accounts);
  const [open, setOpen] = useState(false);
  const gitAccounts = store.gitchAccounts;
  const [sheet, setSheet] = useState<AccountSheet | null>(null);
  const [position, setPosition] = useState({ top: 89, right: 12 });
  const trigger = useRef<HTMLButtonElement>(null), popup = useRef<HTMLDivElement>(null);
  const account = store.hostingAccount;
  const candidates = store.target ? accounts.candidates(store.target) : [];
  // without a GitHub/GitLab remote there is no repository account; show what is connected instead
  const connectedOnly = accounts.accounts;
  const chosen = connectedOnly.find((value) => value.id === store.hostingHub.selectedAccountID);
  const shown = account ?? (!store.target ? chosen ?? connectedOnly[0] : null) ?? null;
  const count = new Set([...connectedOnly.map((value) => gitAccountKey(accountHost(value), value.username)), ...gitAccounts.map((value) => gitAccountKey(value.hosts, value.id))]).size;
  const others = shown && count > 1 ? ` +${count - 1}` : "";
  // a repository's own identity, or the global one while no repository is open
  const identity = store.path ? store.me : store.globalIdentity;
  const locked = !!store.gitchStatus?.lockedAccount;
  const gitAccount = store.gitchStatus?.lockedAccount || store.gitchStatus?.account || identity?.name || t("Not configured");
  useEffect(() => { if (!store.path) void store.loadGlobalIdentity(); }, [store, store.path, open]);
  useEffect(() => {
    if (!open) return;
    const positionPopup = () => {
      const bounds = trigger.current?.getBoundingClientRect();
      if (bounds) setPosition({ top: bounds.bottom + 8, right: Math.max(12, window.innerWidth - bounds.right) });
    };
    positionPopup(); window.addEventListener("resize", positionPopup);
    popup.current?.querySelector<HTMLElement>("select,button")?.focus();
    const onClick = (event: MouseEvent) => {
      if (event.target instanceof Node && !popup.current?.contains(event.target) && !trigger.current?.contains(event.target)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); setOpen(false); trigger.current?.focus(); }
    };
    document.addEventListener("mousedown", onClick); window.addEventListener("keydown", onKey, true);
    return () => { document.removeEventListener("mousedown", onClick); window.removeEventListener("keydown", onKey, true); window.removeEventListener("resize", positionPopup); };
  }, [open]);
  useEffect(() => { setOpen(false); setSheet(null); }, [store.id, store.path]);
  const present = (request: AccountSheet) => { setOpen(false); setSheet(request); };
  const choose = (value: (typeof accounts.accounts)[number]) => {
    if (store.path && candidates.some((candidate) => candidate.id === value.id)) store.useAccount(value);
    else { store.hostingHub.selectedAccountID = value.id; store.navigate("account"); }
    setOpen(false);
  };
  const connected = (login: string) => {
    const value = accounts.accounts.find((item) => item.provider === "github" && accountHost(item) === "github.com" && item.username.toLowerCase() === login.toLowerCase());
    if (value && store.target && accounts.candidates(store.target).some((item) => item.id === value.id) && (!store.hostingAccount || store.hostingAccount.id === value.id)) store.useAccount(value);
    setSheet(null);
  };
  return <>
    <button ref={trigger} className="account-quick-trigger" aria-label={t("Accounts")} aria-expanded={open} aria-haspopup="dialog" onClick={() => setOpen(!open)} data-tip={t("View and manage the repository account and Git identity")}>
      {shown ? <Avatar name={shown.name ?? shown.username} email={shown.username} url={shown.avatarURL} size={26} /> : <UserRound size={24} />}
      <span className="account-quick-summary"><strong>{shown ? `@${shown.username}${others}` : !store.target && gitAccounts.length ? `${t("Git accounts")} (${count})` : t("Connect account")}</strong><small>{locked && <LockKeyhole size={10} />}{store.path ? t("Git: {0}", gitAccount) : t("Open repository…")}</small></span>
      <ChevronDown size={11} />
    </button>
    {open && createPortal(<div ref={popup} className="account-quick-popover" style={{ top: position.top, right: position.right, maxHeight: `calc(100dvh - ${position.top + 16}px)` }} role="dialog" aria-label={t("Accounts")}>
      {!store.target ? <>
        <div className="account-quick-heading">
          <div className="account-quick-profile"><strong>{t("Connected accounts")}</strong></div>
          <button className="icon-btn" aria-label={t("Close")} onClick={() => { setOpen(false); trigger.current?.focus(); }}><X size={15} /></button>
        </div>
      </> : <div className="account-quick-heading">
        {account ? <Avatar name={account.name ?? account.username} email={account.username} url={account.avatarURL} size={40} /> : <UserRound size={36} />}
        <div className="account-quick-profile"><strong>{account?.name ?? account?.username ?? t("Repository account")}</strong>{account ? <><span>@{account.username} · {providerInfo[account.provider].title}</span><small>{accountHost(account)}</small></> : <span>{t("Connect an account for repository services.")}</span>}</div>
        <button className="icon-btn" aria-label={t("Close")} onClick={() => { setOpen(false); trigger.current?.focus(); }}><X size={15} /></button>
      </div>}
      {candidates.length > 0 ? <label className="account-quick-selector"><span>{t("Account for this repository")}</span><select className="input" value={account?.id ?? ""} onChange={(event) => { const next = candidates.find((item) => item.id === event.target.value); if (next) store.useAccount(next); }}>{candidates.map((item) => <option key={item.id} value={item.id}>@{item.username} · {accountHost(item)}</option>)}</select></label> : store.target && <p className="hint">{t("Connect an account on {0} to use repository services.", store.target.host)}</p>}
      {connectedOnly.length > 0 && <section className="account-quick-connections"><strong>{t("Connected accounts")}</strong><ul className="account-quick-list">
        {connectedOnly.map((item) => <li key={item.id}><button type="button" aria-pressed={item.id === shown?.id} onClick={() => choose(item)}><Avatar name={item.name ?? item.username} email={item.username} url={item.avatarURL} size={24} /><span>@{item.username} · {accountHost(item)}</span></button></li>)}
      </ul></section>}
      {gitAccounts.length > 0 && <section className="account-quick-connections"><strong>{t("Git accounts")}</strong><ul className="account-quick-list account-quick-git-list">{gitAccounts.map((item) => <li key={item.id}><GitAccountAvatar account={item} /><span><strong>{item.id}</strong><small>{item.hosts}</small></span></li>)}</ul><Button size="small" onClick={() => { setOpen(false); window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: "cli" })); }}>{t("Manage Git accounts…")}</Button></section>}
      <section className="account-quick-identity">
        {!store.path ? <><p className="hint">{t("Open a repository to see its Git identity.")}</p><Button onClick={() => { setOpen(false); void store.pickAndOpen(); }}>{t("Open repository…")}</Button></> : <>
        <div className="row"><strong>{t("Git identity")}</strong><span className="spacer" />{locked && <span className="row hint"><LockKeyhole size={12} />{t("Locked")}</span>}</div>
        <dl><dt>{t("Git account")}</dt><dd>{gitAccount}</dd><dt>{t("Author")}</dt><dd>{identity?.name || t("Not configured")}</dd><dt>{t("Email")}</dt><dd>{identity?.email || t("Not configured")}</dd></dl>
        <p className="hint">{t("Git author and SSH identity follow this repository's Git account rules.")}</p>
        <Button size="small" disabled={store.gitchChecking} onClick={() => void (store.path ? store.refreshGitch() : store.loadGlobalIdentity())}>{t("Refresh account status")}</Button>
        </>}
      </section>
      <div className="account-quick-actions">
        {account?.provider === "github" && accountHost(account) === "github.com" && <><Button onClick={() => present({ kind: "login", expectedLogin: account.username, capability: "standard" })}>{t("Renew browser connection…")}</Button><Button onClick={() => present({ kind: "login", expectedLogin: account.username, capability: "projects" })}>{t("Connect GitHub project access")}</Button></>}
        <Button onClick={() => present({ kind: "login", capability: "standard" })}>{t("Connect another GitHub account…")}</Button>
        <Button onClick={() => present({ kind: "connections" })}>{t("Add or remove connected accounts…")}</Button>
      </div>
    </div>, document.body)}
    {sheet && createPortal(<SharedSheet title={sheet.kind === "connections" ? t("Connected accounts") : sheet.capability === "projects" ? t("Connect GitHub project access") : t("Sign in to GitHub")} context={sheet.kind === "login" && sheet.expectedLogin ? `@${sheet.expectedLogin} · github.com` : null} width={620} onClose={() => setSheet(null)} cancelLabel={t("Done")}>
      {sheet.kind === "connections" ? <AccountConnections /> : <GitchBrowserLogin capability={sheet.capability} expectedLogin={sheet.expectedLogin} onConnected={connected} />}
    </SharedSheet>, document.body)}
  </>;
}
