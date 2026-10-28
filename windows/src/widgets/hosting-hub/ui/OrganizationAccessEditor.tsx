import { useEffect, useRef, useState, type ReactNode } from "react";
import { X } from "lucide-react";
import { resolveHubOrganizationMember, readHubOrganizationMemberAccess, readHubOrganizationTeamAccess, setHubOrganizationMemberRole, setHubOrganizationTeamRole, hubError, type HostingHubStore, type HubDetail, type HubMember, type HubOrganizationTeam, type HubOrganizationMemberAccess, type HubAccess } from "@/entities/hosting";
import { accountHost } from "@/entities/git";
import { Button, Spinner } from "@/shared/ui";
import { t } from "@/shared/i18n";

type Review = (title: string, body: string, action: (c: HubAccess) => Promise<unknown>) => void;
export interface OrganizationAccessTarget { member?: HubMember; team?: HubOrganizationTeam }

/** Membership roles are read from the provider before a role is chosen or reviewed. */
export function OrganizationAccessEditor({ hub, detail, target, ask, close, saved }: { hub: HostingHubStore; detail: HubDetail; target: OrganizationAccessTarget; ask: Review; close: () => void; saved: (notice: string) => void }) {
  const people = [...detail.members, ...(detail.organization?.teams.flatMap(team => team.members) ?? [])].filter((member, index, all) => all.findIndex(value => value.id === member.id) === index);
  const [personID, setPersonID] = useState(target.member?.id ?? "");
  const [resolvedPerson, setResolvedPerson] = useState<HubMember | null>(null), [username, setUsername] = useState("");
  const person = resolvedPerson ?? people.find(member => member.id === personID) ?? (target.member?.id === personID ? target.member : undefined);
  const [access, setAccess] = useState<HubOrganizationMemberAccess | null>(null), [role, setRole] = useState(""), [loading, setLoading] = useState(false), [error, setError] = useState("");
  const stamp = useRef(hub.actionStamp).current;
  const gitlab = hub.provider === "gitlab", team = target.team;
  const stale = stamp !== hub.actionStamp;
  const matchesPerson = !!access && !!person && access.userID === person.id && access.username.toLowerCase() === person.username.toLowerCase();
  const directGrant = gitlab && !!team && !!access?.inherited && !access.direct;
  const inherited = !!access?.inherited && !directGrant, custom = !!access?.customRole;
  useEffect(() => {
    let current = true;
    setAccess(null); setError("");
    if (!person) return;
    setLoading(true);
    void (async () => {
      let token: string | undefined;
      try {
        const captured = await hub.access(); token = captured.token;
        const context = { ...captured, stillCurrent: () => current && captured.stillCurrent?.() !== false && hub.actionStamp === stamp };
        const result = team ? await readHubOrganizationTeamAccess(context, detail.item, team, person) : await readHubOrganizationMemberAccess(context, detail.item, person);
        if (current) { setAccess(result); setRole(gitlab && team && result.inherited && !result.direct ? ["10", "15", "20", "30", "40", "50"].find(value => Number(value) > Number(result.effectiveRole)) ?? "" : result.role || (gitlab ? "30" : "member")); }
      } catch (failure) { if (current) setError(hubError(failure, token)); }
      finally { if (current) setLoading(false); }
    })();
    return () => { current = false; };
  }, [hub, detail.item, person, team, stamp, gitlab]);
  const resolvePerson = async () => {
    setLoading(true); setError(""); let token: string | undefined;
    try { const captured = await hub.access(); token = captured.token; const context = { ...captured, stillCurrent: () => captured.stillCurrent?.() !== false && hub.actionStamp === stamp }; const member = await resolveHubOrganizationMember(context, detail.item, username); if (hub.actionStamp === stamp) { setResolvedPerson(member); setPersonID(member.id); } }
    catch (failure) { setError(hubError(failure, token)); } finally { setLoading(false); }
  };
  useEffect(() => { if (access) document.querySelector<HTMLElement>(".organization-dialog [data-organization-role]")?.focus(); }, [access]);
  const review = () => {
    if (!person || !access || !matchesPerson || inherited || custom || stale) return;
    const selected = role, snapshot = access;
    ask(directGrant ? t("Grant direct subgroup access?") : team ? t("Grant team access?") : t("Change organization access?"), `${detail.item.title}${team ? ` · ${team.name}` : ""}\n${hub.account ? accountHost(hub.account) : ""} · @${hub.account?.username ?? ""}\n${person.name} · @${person.username}\n${t("Current role")}: ${snapshot.exists ? organizationRoleName(snapshot.role) : t("No direct access")}\n${t("New role")}: ${organizationRoleName(selected)}\n\n${directGrant ? t("This adds a direct subgroup role. The inherited parent-group role stays in place.") : organizationRoleMeaning(selected, !!team, false)}`, async context => {
      const notice = team ? await setHubOrganizationTeamRole(context, detail.item, team, snapshot, selected) : await setHubOrganizationMemberRole(context, detail.item, snapshot, selected);
      saved(notice ?? t("Access updated. The organization has been refreshed.")); close();
    });
  };
  const choices = gitlab ? ["10", "15", "20", "30", "40", "50"] : team ? ["member", "maintainer"] : ["member", "admin"];
  return <OrganizationDialog busy={hub.busy} title={team ? t("Team access") : t("Organization access")} close={close}>
    <p className="hint">{detail.item.title}{team ? ` · ${team.name}` : ""}</p>
    {target.member ? <strong>{target.member.name} · @{target.member.username}</strong> : <label>{t("Organization member")}<select className="select" aria-label={t("Organization member")} value={personID} disabled={loading || hub.busy} onChange={event => { setResolvedPerson(null); setPersonID(event.target.value); }}><option value="">{t("Choose a loaded member")}</option>{resolvedPerson && !people.some(member => member.id === resolvedPerson.id) && <option value={resolvedPerson.id}>{resolvedPerson.name} · @{resolvedPerson.username}</option>}{people.filter(member => member.username.toLowerCase() !== hub.account?.username.toLowerCase()).map(member => <option key={member.id} value={member.id}>{member.name} · @{member.username}</option>)}</select></label>}
    {!target.member && <div className="organization-username-lookup"><label>{t("Existing member username")}<input className="input" aria-label={t("Existing member username")} value={username} disabled={loading || stale} onChange={event => setUsername(event.target.value)}/></label><Button size="small" disabled={!username.trim() || loading || stale} onClick={() => void resolvePerson()}>{t("Load current access")}</Button><p className="hint">{t("Only existing active organization members can receive access here.")}</p></div>}
    {loading && <p className="row"><Spinner/>{t("Checking current access…")}</p>}
    {error && <p className="error-text" role="alert">{error}</p>}
    {stale && <p className="error-text" role="alert">{t("The organization changed. Close this editor and open it again.")}</p>}
    {directGrant && <p className="hub-notice">{t("This person inherits access from a parent group. You can grant a higher direct role in this subgroup.")}</p>}
    {access && <><p>{t("Current role")}: <strong>{access.exists ? organizationRoleName(access.effectiveRole) : t("No direct access")}</strong></p>{inherited ? <p className="hub-notice">{t("This access is inherited. Change the role in the parent group that grants it.")}</p> : custom ? <p className="hub-notice">{t("Custom roles must be managed in the provider to preserve their permissions.")}</p> : <><label>{t("New role")}<select className="select" aria-label={t("New role")} data-organization-role value={role} disabled={loading || stale || hub.busy} onChange={event => setRole(event.target.value)}>{choices.filter(value => !directGrant || Number(value) > Number(access.effectiveRole)).map(value => <option key={value} value={value}>{organizationRoleName(value)}</option>)}</select></label><p className="organization-role-meaning">{organizationRoleMeaning(role, !!team, false)}</p></>}</>}
    <div className="hub-actions"><Button kind="primary" disabled={!access || !matchesPerson || loading || inherited || custom || stale || hub.busy || hub.uncertainWrite || hub.organizationLoading || !role || role === access.role} onClick={review}>{t("Review access change")}</Button><Button disabled={hub.busy} onClick={close}>{t("Cancel")}</Button></div>
  </OrganizationDialog>;
}

/** Focus and dismissal stay local so a review sheet can safely open above the editor. */
export function OrganizationDialog({ title, children, close, busy = false }: { busy?: boolean; title: string; children: ReactNode; close: () => void }) {
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => { const previous = document.activeElement as HTMLElement | null; const first = panel.current?.querySelector<HTMLElement>("input:not(:disabled), select:not(:disabled), button:not(:disabled):not(.organization-dialog-close)"); (first ?? panel.current)?.focus(); return () => { if (previous?.isConnected) previous.focus(); }; }, []);
  return <div className="organization-dialog-backdrop" onMouseDown={event => { if (!busy && event.target === event.currentTarget) close(); }}><div ref={panel} tabIndex={-1} className="organization-dialog" role="dialog" aria-modal="true" aria-label={title} onKeyDown={event => {
    if (event.key === "Escape") { event.stopPropagation(); if (!busy) close(); }
    if (event.key === "Tab") { const controls = [...event.currentTarget.querySelectorAll<HTMLElement>("button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled)")], first = controls[0], last = controls.at(-1); if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); } else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); } }
  }}><header><h3>{title}</h3><Button className="organization-dialog-close" tip={t("Close")} aria-label={t("Close")} disabled={busy} onClick={close}><X size={15}/></Button></header>{children}</div></div>;
}

export const organizationRoleName = (role: string): string => ({ direct_member: t("Member"), member: t("Member"), admin: t("Owner"), billing_manager: t("Billing manager"), maintainer: t("Team maintainer"), "10": t("Guest"), "15": t("Planner"), "20": t("Reporter"), "30": t("Developer"), "40": t("Maintainer"), "50": t("Owner") })[role] ?? role;
export function organizationRoleMeaning(role: string, team: boolean, invitation: boolean): string {
  if (team && role === "50") return t("Subgroup owners can manage this subgroup's members and settings.");
  if (role === "admin" || role === "50") return t("Owners can manage members, permissions and organization settings.");
  if (role === "billing_manager") return t("Billing managers manage billing without access to repositories.");
  if (role === "maintainer") return t("Team maintainers can manage this team's members and settings.");
  if (role === "40") return t("Maintainers can manage projects and their development settings.");
  if (role === "30") return t("Developers can contribute code and work with project issues and merge requests.");
  if (role === "20") return t("Reporters can read code and review project activity.");
  if (role === "15") return t("Planners can manage planning work without code contribution access.");
  if (role === "10") return t("Guests have limited access to issues and collaboration.");
  return team ? t("Team members receive the repository access granted to this team.") : invitation ? t("Members join the organization and receive access according to its policies.") : t("Members receive access according to organization and team policies.");
}
