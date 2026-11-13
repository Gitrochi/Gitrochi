import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { accountHost, type HostAccount, type Provider } from "@/entities/git";
import type { GitHubLoginCapability } from "@/entities/gitch";
import { type AccountStatus, accounts, toolbarAccountBadge } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { AccountAvatar, AddAccountSheet, GitHubSignInSheet } from "@/features/account-connection";
import { designIcon } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { tip } from "@/shared/ui";
import { AccountPopover } from "./AccountPopover";
import "./account-quick-controls.css";

const SignedOut = designIcon("account");

type AccountSheet = { kind: "add"; provider?: Provider; server?: string } | { kind: "login"; expectedLogin?: string; capability: GitHubLoginCapability };

/**
 * The toolbar's last item (docs/design.md, App shell): the 24 px profile photo of the account this repository uses,
 * with a warning badge only while that account needs attention, opening the one account popover.
 * (macOS: AccountQuickControls)
 */
export function AccountQuickControls({ store }: { store: RepoStore }) {
  useObserve(store); useObserve(accounts);
  const [open, setOpen] = useState(false);
  const [sheet, setSheet] = useState<AccountSheet | null>(null);
  const [position, setPosition] = useState({ top: 89, right: 12 });
  const trigger = useRef<HTMLButtonElement>(null), popup = useRef<HTMLDivElement>(null);
  const account = store.hostingAccount;
  // without a repository account the photo is the account the Account page shows
  const shown = account ?? (!store.target ? accounts.accounts.find((value) => value.id === store.hostingHub.selectedAccountID) ?? accounts.accounts[0] : null) ?? null;
  const badge = toolbarAccountBadge(account ? accounts.status(account) : null);
  useEffect(() => {
    if (!open) return;
    const positionPopup = () => {
      const bounds = trigger.current?.getBoundingClientRect();
      if (bounds) setPosition({ top: bounds.bottom + 8, right: Math.max(12, window.innerWidth - bounds.right) });
    };
    positionPopup(); window.addEventListener("resize", positionPopup);
    popup.current?.querySelector<HTMLElement>("button")?.focus();
    const onClick = (event: MouseEvent) => {
      // the Change… menu is drawn outside the popover and belongs to it
      if (event.target instanceof Element && !popup.current?.contains(event.target) && !trigger.current?.contains(event.target) && !event.target.closest(".menu")) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); setOpen(false); trigger.current?.focus(); }
    };
    document.addEventListener("mousedown", onClick); window.addEventListener("keydown", onKey, true);
    return () => { document.removeEventListener("mousedown", onClick); window.removeEventListener("keydown", onKey, true); window.removeEventListener("resize", positionPopup); };
  }, [open]);
  useEffect(() => { setOpen(false); setSheet(null); }, [store.id, store.path]);
  const present = (request: AccountSheet) => { setOpen(false); setSheet(request); };
  /** A new or renewed account becomes this repository's when the repository has none, or it is the one in use */
  const connected = (value: HostAccount) => {
    if (store.target && accounts.candidates(store.target).some((item) => item.id === value.id) && (!store.hostingAccount || store.hostingAccount.id === value.id)) store.useAccount(value);
  };
  /** github.com accounts renew in the browser; a GitLab server takes a new token in the Add account sheet */
  const resolve = (value: HostAccount, _status: AccountStatus) => {
    if (value.provider === "github" && accountHost(value) === "github.com") present({ kind: "login", expectedLogin: value.username, capability: "standard" });
    else present({ kind: "add", provider: value.provider, server: value.server });
  };
  const label = shown ? `@${shown.username} · ${accountHost(shown)}` : t("No account");
  return <>
    <button ref={trigger} className={`account-quick-trigger ${open ? "open" : ""}`} aria-label={t("Accounts")} aria-expanded={open} aria-haspopup="dialog" onClick={() => setOpen(!open)}
      data-attention={badge || undefined} data-tip={tip(label, badge ? t("This repository's account needs attention") : undefined)}>
      <span className="account-quick-photo">
        {shown ? <AccountAvatar account={shown} size={24} /> : <SignedOut size={22} strokeWidth={1.3} />}
        {badge && <span className="account-quick-badge status-tone" data-tone="waiting" role="img" aria-label={t("This repository's account needs attention")}>!</span>}
      </span>
    </button>
    {open && createPortal(<div ref={popup} className="account-quick-popover" style={{ top: position.top, right: position.right, maxHeight: `calc(100dvh - ${position.top + 16}px)` }} role="dialog" aria-label={t("Accounts")}>
      <AccountPopover store={store} actions={{
        resolve,
        inbox: () => { setOpen(false); store.navigate("account"); },
        addAccount: () => present({ kind: "add", provider: store.target?.provider === "gitlab" ? "gitlab" : "github" }),
        manageAccounts: () => { setOpen(false); window.dispatchEvent(new CustomEvent("gitrochi-open-settings", { detail: "accounts" })); },
      }} />
    </div>, document.body)}
    {sheet && createPortal(sheet.kind === "add"
      ? <AddAccountSheet provider={sheet.provider} server={sheet.server} onClose={() => setSheet(null)} onConnected={connected} />
      : <GitHubSignInSheet expectedLogin={sheet.expectedLogin} capability={sheet.capability} onClose={() => setSheet(null)} onConnected={connected} />, document.body)}
  </>;
}
