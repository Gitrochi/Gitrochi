import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { ArrowDownToLine, Book, Building2, Check, ChevronsUpDown, CircleX, Monitor, RefreshCw } from "lucide-react";
import { avatars } from "@/entities/avatar";
import { accountHost, type HostAccount } from "@/entities/git";
import { accounts, hubProjectOrganization, type HubProjectScope } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Avatar, Button, Spinner } from "@/shared/ui";
import type { ProjectScopeCatalogs } from "../model/project-scope-catalogs";
import "./project-scope-menu.css";

/**
 * The Projects page's scope button, as the redesign's Projects board draws it: whose projects are shown, with a menu of
 * every connected account, its own projects and its organizations. Local projects have no owner, so they get a fixed
 * label instead. macOS: ProjectScopeMenu.
 */
export function ProjectScopeMenu({ catalogs, account, scope, repositoryOwner, count, more, loading, local, disabled = false, onChange }: {
  catalogs: ProjectScopeCatalogs;
  /** The account whose projects are shown; null for local projects */
  account: HostAccount | null;
  scope: HubProjectScope;
  /** The open repository's owner under an account that can reach it (GitLab: the whole path) */
  repositoryOwner: (account: HostAccount) => string | null;
  count: number;
  more: boolean;
  loading: boolean;
  local: boolean;
  disabled?: boolean;
  onChange: (scope: HubProjectScope, accountID: string) => void;
}) {
  useObserve(accounts); useObserve(catalogs); useObserve(avatars);
  const [open, setOpen] = useState(false), [other, setOther] = useState(false), [login, setLogin] = useState("");
  const root = useRef<HTMLDivElement>(null);
  const all = accounts.accounts, several = all.length > 1, gitlab = account?.provider === "gitlab";
  // The account on the page is read at once; the others wait until the menu opens, not for every visit to the page.
  useLayoutEffect(() => { if (account && !local) catalogs.load(account, accounts.revision); }, [catalogs, account?.id, local, accounts.revision]);
  useLayoutEffect(() => { if (open) for (const value of all) catalogs.load(value, accounts.revision); }, [catalogs, open, all, accounts.revision]);
  useEffect(() => {
    if (!open) return;
    const outside = (event: MouseEvent) => { if (!root.current?.contains(event.target as Node)) setOpen(false); };
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") { event.stopPropagation(); setOpen(false); } };
    window.addEventListener("mousedown", outside);
    window.addEventListener("keydown", key, true);
    return () => { window.removeEventListener("mousedown", outside); window.removeEventListener("keydown", key, true); };
  }, [open]);

  const organization = account ? hubProjectOrganization(scope, account.provider) : null;
  const chosen = account && organization ? catalogs.state(account).items.find((item) => item.id.toLowerCase() === organization.toLowerCase()) : undefined;
  const owner = account ? repositoryOwner(account) : null;
  const title = local ? t("This PC") : organization ? chosen?.title ?? organization : scope === "repository" && owner ? owner : gitlab ? t("Choose a group") : t("My projects");
  const counted = loading && !count ? t("Loading…") : count === 1 && !more ? t("1 project") : `${t("{0} projects", count)}${more ? "+" : ""}`;
  // With several accounts the account leads, so it is the count that gives way when the line is short.
  const subtitle = !local && several && account ? `@${account.username} · ${counted}` : counted;
  const person = (value: HostAccount, size: number) => <Avatar name={value.name ?? value.username} email={value.username} size={size} url={avatars.enabled ? value.avatarURL : null} />;
  const square = (name: string, id: string, size: number, url?: string | null) => <span className="project-scope-square"><Avatar name={name} email={id} size={size} url={avatars.enabled ? url ?? null : null} /></span>;
  const label = <>
    {local ? <span className="project-scope-device" aria-hidden><Monitor size={14} /></span>
      : organization ? square(chosen?.title ?? organization, organization, 24, chosen?.avatarURL)
        : scope === "repository" && owner ? square(owner, owner, 24)
          : account ? person(account, 24) : null}
    <span className="project-scope-text"><span className="project-scope-title">{title}</span><span className="project-scope-sub">{subtitle}</span></span>
  </>;
  if (local) return <div className="project-scope fixed" role="group" aria-label={`${t("Project scope")}: ${title}, ${subtitle}`}>{label}</div>;

  const entered = account ? hubProjectOrganization(`organization:${login.trim()}`, account.provider) : null;
  const choose = (value: HostAccount, next: HubProjectScope) => { setOpen(false); onChange(next, value.id); };
  const openOrganization = () => {
    if (!entered || !account || disabled) return;
    // The list's own spelling wins, so a typed login never looks like a second organization.
    const known = catalogs.state(account).items.find((item) => item.id.toLowerCase() === entered.toLowerCase())?.id ?? entered;
    setOpen(false); setOther(false);
    onChange(`organization:${known}`, account.id);
  };
  const pick = (value: HostAccount, next: HubProjectScope, text: string, icon: ReactNode) => {
    const on = value.id === account?.id && next.toLowerCase() === (organization ? `organization:${organization}` : scope).toLowerCase();
    return <button key={`${value.id}:${next}`} type="button" className="project-scope-item" role="menuitemradio" aria-checked={on} data-account={value.id} data-scope={next} disabled={disabled} onClick={() => choose(value, next)}>
      <span className="project-scope-check">{on && <Check size={13} />}</span><span className="project-scope-slot">{icon}</span><span className="project-scope-label">{text}</span>
    </button>;
  };
  const action = (key: string, text: string, icon: ReactNode, run: () => void) =>
    <button key={key} type="button" className="project-scope-item" role="menuitem" disabled={disabled} onClick={run}>
      <span className="project-scope-check" /><span className="project-scope-slot">{icon}</span><span className="project-scope-label">{text}</span>
    </button>;
  const note = (key: string, text: string, spin: boolean) =>
    <span key={key} className="project-scope-note" role="menuitem" aria-disabled="true"><span className="project-scope-check" /><span className="project-scope-slot">{spin && <Spinner size={13} />}</span>{text}</span>;
  const section = (value: HostAccount) => {
    const catalog = catalogs.state(value), group = value.provider === "gitlab", repository = repositoryOwner(value);
    return [
      several && <span key={`${value.id}:head`} className="project-scope-head" role="presentation">@{value.username} · {accountHost(value)}</span>,
      !group && pick(value, "personal", t("My projects"), person(value, 20)),
      repository && pick(value, "repository", repository, <Book size={13} />),
      !several && <span key={`${value.id}:div`} className="project-scope-divider" role="separator" />,
      !several && <span key={`${value.id}:title`} className="project-scope-head" role="presentation">{group ? t("Groups") : t("Organizations")}</span>,
      ...catalog.items.map((item) => pick(value, `organization:${item.id}`, item.title, square(item.title, item.id, 20, item.avatarURL))),
      catalog.loading ? note(`${value.id}:loading`, group ? t("Loading…") : t("Loading organizations…"), true)
        : catalog.error ? action(`${value.id}:retry`, group ? t("Retry") : t("Retry organizations"), <RefreshCw size={13} />, () => void catalog.load(catalog.items.length > 0))
          : !catalog.items.length && note(`${value.id}:none`, group ? t("No groups found") : t("No organizations found"), false),
      !catalog.loading && !catalog.error && catalog.more && action(`${value.id}:more`, group ? t("Load more") : t("Load more organizations"), <ArrowDownToLine size={13} />, () => void catalog.load(true)),
      <span key={`${value.id}:end`} className="project-scope-divider" role="separator" />,
    ];
  };
  return <div className="project-scope-anchor" ref={root}>
    <button type="button" className={`project-scope ${several ? "wide" : ""}`} aria-haspopup="menu" aria-expanded={open} aria-label={`${t("Project scope")}: ${title}, ${subtitle}`} data-scope={organization ? `organization:${chosen?.id ?? organization}` : scope}
      onClick={() => { setOther(false); setOpen(!open); }}>
      {label}<ChevronsUpDown size={12} aria-hidden />
    </button>
    {open && (other
      ? <div className="project-scope-pop" role="dialog" aria-label={gitlab ? t("Other group…") : t("Other organization…")}>
          <label><span>{gitlab ? t("Group path") : t("Organization login")}</span>
            <input className="input" autoFocus aria-label={gitlab ? t("Group path") : t("Organization login")} value={login} disabled={disabled} onChange={(event) => setLogin(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); openOrganization(); } }} />
          </label>
          <div><Button disabled={disabled || !entered} onClick={openOrganization}>{gitlab ? t("Open") : t("Open organization")}</Button></div>
        </div>
      : <div className="project-scope-menu" role="menu" aria-label={t("Project scope")}>
          {all.flatMap(section)}
          {action("other", gitlab ? t("Other group…") : t("Other organization…"), <Building2 size={13} />, () => { setLogin(""); setOther(true); })}
        </div>)}
  </div>;
}

/** The strip under the scope row when the account's organizations could not be read: the page keeps working with the user's own projects, so it says that and offers the retry. macOS: ProjectScopeFailureStrip. */
export function ProjectScopeFailureStrip({ catalogs, account }: { catalogs: ProjectScopeCatalogs; account: HostAccount | null }) {
  useObserve(catalogs);
  if (!account || !catalogs.failed(account)) return null;
  const state = catalogs.state(account), gitlab = account.provider === "gitlab";
  return <div className="project-scope-strip" role="status" title={state.error ?? undefined}>
    <CircleX size={14} aria-hidden />
    <span><strong>{gitlab ? t("Couldn't load groups.") : t("Couldn't load organizations.")}</strong><small>{gitlab ? t("Repository boards are still available.") : t("Your personal projects are still available.")}</small></span>
    <Button disabled={state.loading} onClick={() => void state.load(state.items.length > 0)}>{t("Retry")}</Button>
  </div>;
}
