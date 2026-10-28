import type { ReactNode } from "react";
import { ExternalLink } from "lucide-react";
import { hubSafeURL, type HostingHubStore, type HubDetail, type HubMember, type HubOrganizationTeam, type HubOrganizationSectionState, type HubOrganizationInvitation } from "@/entities/hosting";
import { accountHost } from "@/entities/git";
import { Avatar, Button, Spinner } from "@/shared/ui";
import { t } from "@/shared/i18n";

/** Organization people and team people are visible together before provider administration links. */
export function OrganizationDashboard({ hub, detail, locked, open, onClone, cancelInvitation, query = "", manage = false, memberAccess, teamAccess }: { query?: string; manage?: boolean; memberAccess?: (member: HubMember, team?: HubOrganizationTeam) => void; teamAccess?: (team: HubOrganizationTeam) => void; hub: HostingHubStore; detail: HubDetail; locked: boolean; open: (url: string) => void; onClone?: (url: string) => void; cancelInvitation: (invitation: HubOrganizationInvitation) => void }) {
  const data = detail.organization;
  if (!data) return null;
  const context = { target: { provider: hub.provider, host: hub.account ? accountHost(hub.account) : "" } };
  const search = query.trim().toLowerCase(), matches = (member: HubMember) => `${member.name} ${member.username}`.toLowerCase().includes(search);
  const people = detail.members.filter(matches), teams = data.teams.filter(team => `${team.name} ${team.description}`.toLowerCase().includes(search) || team.members.some(matches));
  return <div className="organization-dashboard">
    <OrganizationSection people title={t("Members")} count={detail.members.length} state={data.sections.members} empty={t("No visible members.")} locked={locked} load={() => void hub.loadOrganizationSection("members")}>
      <div className="organization-people">{people.map(member => <OrganizationPerson key={member.id} member={member} open={open} manage={manage && memberAccess ? () => memberAccess(member) : undefined} own={member.username.toLowerCase() === hub.account?.username.toLowerCase()} organizationMember={hub.provider === "github"}/>)}</div>
    </OrganizationSection>
    <OrganizationSection title={hub.provider === "gitlab" ? t("Subgroups") : t("Teams")} count={data.teams.length} state={data.sections.teams} empty={hub.provider === "gitlab" ? t("No visible subgroups.") : t("No visible teams.")} locked={locked} load={() => void hub.loadOrganizationSection("teams")}>
      <div className="organization-team-list">{teams.map(team => <OrganizationTeamCard key={team.id} team={team} locked={locked} open={open} load={() => void hub.loadOrganizationSection("teams", team.id)} assign={teamAccess ? () => teamAccess(team) : undefined} memberAccess={manage && memberAccess ? member => memberAccess(member, team) : undefined} me={hub.account?.username}/>)}</div>
    </OrganizationSection>
    <OrganizationSection title={t("Repositories")} count={detail.repositories.length} state={data.sections.repositories} empty={t("No visible repositories.")} locked={locked} load={() => void hub.loadOrganizationSection("repositories")}>
      <div className="organization-repository-list">{detail.repositories.map(repository => <article className="organization-repository" key={repository.id}><div><strong>{repository.name}</strong><p className="hint">{repository.description}</p></div><div className="hub-actions">{hubSafeURL(context, repository.url) && <Button size="small" tip={t("Open in browser")} onClick={() => open(repository.url)}><ExternalLink size={13}/></Button>}<Button size="small" disabled={locked || !hubSafeURL(context, repository.cloneURL)} onClick={() => onClone ? onClone(repository.cloneURL) : void navigator.clipboard.writeText(repository.cloneURL)}>{onClone ? t("Clone") : t("Copy clone URL")}</Button></div></article>)}</div>
    </OrganizationSection>
    <OrganizationSection title={t("Invitations")} count={data.invitations.length} state={data.sections.invitations} empty={t("No pending invitations.")} locked={locked} load={() => void hub.loadOrganizationSection("invitations")}>
      <div className="organization-invitation-list">{data.invitations.map(invitation => <article className="organization-invitation" key={invitation.id}><div><strong>{invitation.name || invitation.email || invitation.id}</strong><span className="hint">{invitation.role}</span>{invitation.expiresAt && <span className="hint">{t("Expires")}: {invitation.expiresAt}</span>}</div>{data.info.canInvite && <Button size="small" disabled={locked || hub.organizationLoading || hub.uncertainWrite} onClick={() => cancelInvitation(invitation)}>{t("Cancel invitation")}</Button>}</article>)}</div>
    </OrganizationSection>
  </div>;
}

function OrganizationSection({ title, count, state, empty, locked, load, children, people = false }: { people?: boolean; title: string; count: number; state: HubOrganizationSectionState; empty: string; locked: boolean; load: () => void; children: ReactNode }) {
  return <section className="organization-section" data-organization-section={title === t("Invitations") ? "invitations" : undefined} aria-label={title}><header><h4>{title}</h4><span className="hint">{people ? t("{0} people loaded", count) : t("{0} loaded", count)}</span></header>{children}{state.error && <div className="organization-section-error" role="status"><p>{state.error}</p><Button size="small" disabled={locked || state.loading} onClick={load}>{t("Retry")}</Button></div>}{!count && state.loaded && !state.error && <p className="hint">{empty}</p>}{state.loading ? <Spinner/> : state.more && <Button size="small" disabled={locked} onClick={load}>{t("Load more")}</Button>}</section>;
}

export function OrganizationPerson({ member, open, compact = false, manage, own = false, organizationMember = false }: { member: HubMember; open: (url: string) => void; compact?: boolean; manage?: () => void; own?: boolean; organizationMember?: boolean }) {
  return <article className={`organization-person ${compact ? "compact" : ""}`}><Avatar name={member.name} email={member.username} url={member.avatarURL} size={compact ? 28 : 36}/><div><strong title={member.name}>{member.name}</strong><span className="hint" title={`@${member.username}`}>@{member.username}</span>{!compact && <span className="hint">{organizationMember ? t("Organization member") : member.role}</span>}</div>{manage && <Button size="small" disabled={own} tip={own ? t("Change your own access in the provider's settings. This workspace does not change your own role.") : t("Manage access")} onClick={manage}>{t("Edit access")}</Button>}{member.url && !manage && <Button size="small" tip={t("Open profile")} onClick={() => open(member.url)}><ExternalLink size={12}/></Button>}</article>;
}

/** Each team keeps its own native member list and pagination on the same card. */
export function OrganizationTeamCard({ team, locked, open, load, assign, memberAccess, me }: { assign?: () => void; memberAccess?: (member: HubMember) => void; me?: string; team: HubOrganizationTeam; locked: boolean; open: (url: string) => void; load: () => void }) {
  const state = team.memberState;
  return <article className="organization-team-card"><header><div><strong>{team.name}</strong>{team.description && <p className="hint">{team.description}</p>}</div>{team.url && <Button size="small" tip={t("Open in browser")} onClick={() => open(team.url)}><ExternalLink size={13}/></Button>}</header>{assign && <Button size="small" disabled={locked} onClick={assign}>{t("Add member")}</Button>}<div className="organization-team-people" aria-label={t("Team members")}>{team.members.map(member => <OrganizationPerson key={member.id} member={member} open={open} compact manage={memberAccess ? () => memberAccess(member) : undefined} own={member.username.toLowerCase() === me?.toLowerCase()}/>)}</div>{state.loaded && <span className="hint">{t("{0} loaded members", team.members.length)}</span>}{state.error && <p className="organization-section-error" role="status">{state.error}</p>}{state.loaded && !team.members.length && !state.error && <p className="hint">{t("No visible members.")}</p>}{state.loading ? <Spinner/> : (state.more || state.error || !state.loaded) && <Button size="small" disabled={locked} onClick={load}>{state.error ? t("Retry") : state.loaded ? t("Load more members") : t("Load members")}</Button>}</article>;
}
