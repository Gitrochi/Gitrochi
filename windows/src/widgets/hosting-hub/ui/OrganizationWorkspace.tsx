import { useEffect, useState } from "react";
import { ExternalLink, MailPlus } from "lucide-react";
import { hubOrganizationInviteError, hubOrganizationLinks, inviteHubOrganizationMember, cancelHubOrganizationInvitation, hubSafeURL, type HostingHubStore, type HubAccess, type HubDetail, type HubOrganizationInviteInput, type HubOrganizationTab, type HubOrganizationInvitation } from "@/entities/hosting";
import { accountHost } from "@/entities/git";
import { Avatar, Button } from "@/shared/ui";
import { t } from "@/shared/i18n";
import "./organization-workspace.css";
import { OrganizationDashboard, OrganizationTeamCard } from "./OrganizationDashboard";

type Review = (title: string, body: string, action: (c: HubAccess) => Promise<unknown>, refresh?: "list" | "detail") => void;

/** A selected organization keeps its account and review context for every action. */
export function OrganizationWorkspace({ hub, detail, locked, open, ask, onClone }: { hub: HostingHubStore; detail: HubDetail; locked: boolean; open: (url: string) => void; ask: Review; onClone?: (url: string) => void }) {
  const gitlab = hub.provider === "gitlab";
  const [inviting, setInviting] = useState(false);
  const [input, setInput] = useState<HubOrganizationInviteInput>({ email: "", role: gitlab ? "30" : "direct_member", expiresAt: "" });
  const [result, setResult] = useState<string | null>(null);
  useEffect(() => { setInviting(false); setInput({ email: "", role: gitlab ? "30" : "direct_member", expiresAt: "" }); setResult(null); }, [detail.item.id, hub.account?.id, gitlab]);
  const context = { target: { provider: hub.provider, host: hub.account ? accountHost(hub.account) : "" } };
  const info = detail.organization?.info;
  const invalid = hubOrganizationInviteError(hub.provider, input);
  const tabs: { id: HubOrganizationTab; title: string }[] = [{ id: "overview", title: t("Overview") }, { id: "repositories", title: t("Repositories") }, { id: "members", title: t("Members") }, { id: "teams", title: gitlab ? t("Subgroups") : t("Teams") }, { id: "invitations", title: t("Invitations") }];
  const links = hubOrganizationLinks(context, detail.item);
  const reviewInvitation = () => {
    if (invalid) return;
    const payload = { ...input };
    ask(t("Invite this member?"), `${detail.item.title}\n${context.target.host} · @${hub.account?.username ?? ""}\n${payload.email.trim()}\n${t("Role")}: ${roleLabel(payload.role)}${payload.expiresAt ? `\n${t("Expires")}: ${payload.expiresAt}` : ""}\n\n${t("The server will send an invitation to this email address.")}`, async access => {
      const notice = await inviteHubOrganizationMember(access, detail.item, payload);
      setResult(notice ?? t("Invitation sent. Refresh invitations to check its status."));
      setInviting(false);
      setInput({ email: "", role: gitlab ? "30" : "direct_member", expiresAt: "" });
    });
  };
  const cancelInvitation = (invitation: HubOrganizationInvitation) => ask(t("Cancel this invitation?"), `${detail.item.title}\n${context.target.host} · @${hub.account?.username ?? ""}\n${invitation.name || invitation.email}\n${t("The recipient will no longer be able to accept this invitation.")}`, access => cancelHubOrganizationInvitation(access, detail, invitation));
  return <div className="organization-workspace">
    <nav className="organization-tabs" aria-label={t("Organization view")}>{tabs.map(tab => <Button key={tab.id} size="small" aria-pressed={hub.tab === tab.id} kind={hub.tab === tab.id ? "primary" : undefined} disabled={locked} onClick={() => { setInviting(false); setResult(null); void hub.select(detail.item, false, tab.id); }}>{tab.title}</Button>)}</nav>
    {result && <p className="hub-notice" role="status">{result}</p>}
    {info?.notice && <p className="hub-notice" role="status">{info.notice}</p>}
    {(hub.tab === "overview" || hub.tab === "invitations") && <div className="organization-access"><div className="organization-summary"><span>{t("Your role")}: <strong>{info?.role ?? t("Unknown")}</strong></span>{hub.tab === "overview" && <>{info?.publicRepositories !== undefined && <span className="organization-stat-chip"><strong>{info.publicRepositories.toLocaleString()}</strong> {t("Public repositories")}</span>}{info?.privateRepositories !== undefined && <span className="organization-stat-chip"><strong>{info.privateRepositories.toLocaleString()}</strong> {t("Private repositories")}</span>}{info?.visibility && <span className="organization-stat-chip">{t("Visibility")}: {info.visibility}</span>}</>}</div>{info?.canInvite ? <Button disabled={locked || hub.organizationLoading || hub.uncertainWrite} onClick={() => setInviting(!inviting)}><MailPlus size={14}/>{t("Invite member")}</Button> : <span className="hint">{t("Inviting members requires organization owner access and the server's approval.")}</span>}</div>}
    {inviting && <form className="hub-form organization-invite" onSubmit={event => { event.preventDefault(); reviewInvitation(); }}>
      <h4>{t("Invite member")}</h4>
      <label>{t("Email address")}<input className="input" type="email" aria-label={t("Email address")} autoComplete="off" value={input.email} disabled={locked} onChange={event => setInput({ ...input, email: event.target.value })}/></label>
      <label>{t("Role")}<select className="select" aria-label={t("Role")} value={input.role} disabled={locked} onChange={event => setInput({ ...input, role: event.target.value })}>{(gitlab ? ["10", "15", "20", "30", "40", "50"] : ["direct_member", "admin", "billing_manager"]).map(role => <option key={role} value={role}>{roleLabel(role)}</option>)}</select></label>
      {gitlab && <label>{t("Expiration date (optional)")}<input className="input" type="date" aria-label={t("Expiration date (optional)")} value={input.expiresAt} disabled={locked} onChange={event => setInput({ ...input, expiresAt: event.target.value })}/></label>}
      {input.email && invalid && <p className="hint" role="status">{invalid}</p>}
      <p className="hint">{t("Review the recipient, organization and role before sending.")}</p>
      <div className="hub-actions"><Button disabled={locked || hub.uncertainWrite || !!invalid} onClick={reviewInvitation}>{t("Review invitation")}</Button><Button disabled={hub.busy} onClick={() => setInviting(false)}>{t("Cancel")}</Button></div>
    </form>}
    {hub.tab === "overview" && <>

      <OrganizationDashboard hub={hub} detail={detail} locked={locked} open={open} onClone={onClone} cancelInvitation={cancelInvitation}/>
      {info?.location && <p><span className="muted">{t("Location")}: </span>{info.location}</p>}
      {info?.website && <p><span className="muted">{t("Website")}: </span><span>{info.website}</span></p>}
      <h4>{t("Organization tools")}</h4><p className="hint">{t("Open the provider's tools for settings, security, billing and other organization features. Availability depends on your role and plan.")}</p>
      <div className="organization-tools">{links.map(link => <Button key={link.url} size="small" onClick={() => open(link.url)}><ExternalLink size={13}/>{link.title}</Button>)}</div>
      <p className="hint">{t("Lists show only information visible to the selected account. Use Load more to fetch additional pages.")}</p>
    </>}
    {hub.tab === "repositories" && <>{detail.repositories.map(repository => <div className="hub-card hub-repo" key={repository.id}><div><strong>{repository.name}</strong><p className="hint">{repository.description}</p></div><div className="hub-actions">{hubSafeURL(context, repository.url) && <Button size="small" onClick={() => open(repository.url)}>{t("Open in browser")}</Button>}<Button disabled={locked || !hubSafeURL(context, repository.cloneURL)} onClick={() => onClone ? onClone(repository.cloneURL) : void navigator.clipboard.writeText(repository.cloneURL)}>{onClone ? t("Clone") : t("Copy clone URL")}</Button></div></div>)}{!detail.repositories.length && <p className="hint">{t("No visible repositories.")}</p>}</>}
    {hub.tab === "members" && <div className="hub-members">{detail.members.map(member => <article className="hub-member" key={member.id}><Avatar name={member.name} email={member.username} url={member.avatarURL} size={44}/><div className="hub-member-identity"><strong>{member.name}</strong><span className="muted">@{member.username}</span><span className="hub-member-role">{member.role}</span></div>{member.url && <Button size="small" tip={t("Open profile")} onClick={() => open(member.url)}><ExternalLink size={13}/>{t("Profile")}</Button>}</article>)}{!detail.members.length && <p className="hint">{t("No visible members.")}</p>}</div>}
    {hub.tab === "teams" && <>{detail.organization?.teams.map(team => <OrganizationTeamCard key={team.id} team={team} locked={locked} open={open} load={() => void hub.loadOrganizationSection("teams", team.id)}/>)}{!detail.organization?.teams.length && !detail.notice && <p className="hint">{gitlab ? t("No visible subgroups.") : t("No visible teams.")}</p>}</>}
    {hub.tab === "invitations" && <>{detail.organization?.invitations.map(invitation => <article className="hub-card organization-invitation" key={invitation.id}><div><strong>{invitation.name || invitation.email || invitation.id}</strong><p className="hint">{invitation.role}</p>{invitation.createdAt && <span className="hint">{t("Created")}: {invitation.createdAt}</span>}{invitation.expiresAt && <p className="hint">{t("Expires")}: {invitation.expiresAt}</p>}</div>{info?.canInvite && <Button size="small" disabled={locked || hub.uncertainWrite} onClick={() => cancelInvitation(invitation)}>{t("Cancel invitation")}</Button>}</article>)}{!detail.organization?.invitations.length && !detail.notice && <p className="hint">{t("No pending invitations.")}</p>}</>}
  </div>;
}

const roleLabel = (role: string): string => ({ direct_member: t("Member"), admin: t("Owner"), billing_manager: t("Billing manager"), "10": t("Guest"), "15": t("Planner"), "20": t("Reporter"), "30": t("Developer"), "40": t("Maintainer"), "50": t("Owner") })[role] ?? role;
