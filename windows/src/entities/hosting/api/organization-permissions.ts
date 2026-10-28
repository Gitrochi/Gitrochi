import { t } from "@/shared/i18n";
import { HostingError } from "./hosting";
import { ensureHubCurrent, hubRequest, hubError, HubUncertainWriteError, type HubAccess, type HubItem, type HubMember } from "./hub";
import type { HubOrganizationTeam } from "./organization-management";

/** A fresh membership snapshot separates direct access from inherited privileges. */
export interface HubOrganizationMemberAccess { organizationID: string; teamID?: string; userID: string; username: string; role: string; effectiveRole: string; exists: boolean; direct: boolean; inherited: boolean; active: boolean; customRole: boolean }
export type HubOrganizationAccessScope = "organization" | "team";
type Row = Record<string, unknown>;
const row = (value: unknown): Row => value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
const text = (value: unknown): string => typeof value === "string" ? value : typeof value === "number" ? String(value) : "";
const enc = encodeURIComponent;
const base = (c: HubAccess, item: HubItem) => `${c.apiBase}/${c.target.provider === "github" ? "orgs" : "groups"}/${enc(item.id)}`;
const sameUser = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
const ownAccessError = () => t("Change your own access in the provider's settings. This workspace does not change your own role.");
const activeError = () => t("This person is not an active organization member. Invite them first, then refresh members.");
const inheritedError = () => t("This access is inherited. Change the role in the parent group that grants it.");
const changedError = () => t("This person's access changed on the server. Refresh and review it again.");
const roles = (c: HubAccess, scope: HubOrganizationAccessScope) => c.target.provider === "github" ? scope === "organization" ? ["member", "admin"] : ["member", "maintainer"] : ["10", "15", "20", "30", "40", "50"];
const validateTarget = (c: HubAccess, member: Pick<HubMember, "id" | "username">) => { ensureHubCurrent(c); if (!member.username || (c.target.provider === "gitlab" && !/^\d+$/.test(member.id))) throw new Error(activeError()); if (sameUser(member.username, c.me)) throw new Error(ownAccessError()); };

async function owner(c: HubAccess, item: HubItem): Promise<void> {
  ensureHubCurrent(c);
  if (c.target.provider === "github") {
    const membership = await hubRequest<Row>(c, `${c.apiBase}/user/memberships/orgs/${enc(item.id)}`);
    if (membership.role !== "admin" || membership.state !== "active" || !sameUser(text(row(membership.user).login), c.me)) throw new Error(t("Only an organization owner can manage access here."));
  } else {
    const user = await hubRequest<Row>(c, `${c.apiBase}/user`);
    if (!text(user.id) || !sameUser(text(user.username), c.me)) throw new Error(t("The repository or account changed. Reopen this action."));
    const membership = await hubRequest<Row>(c, `${base(c, item)}/members/all/${enc(text(user.id))}`);
    if (Number(membership.access_level) !== 50 || text(membership.id) !== text(user.id) || !sameUser(text(membership.username), c.me) || (membership.membership_state !== undefined && membership.membership_state !== "active")) throw new Error(t("Only an organization owner can manage access here."));
  }
}

async function optional(c: HubAccess, url: string): Promise<Row | null> {
  try { return await hubRequest<Row>(c, url); }
  catch (error) { ensureHubCurrent(c); if (error instanceof HostingError && error.status === 404) return null; throw error; }
}
function validateGitLabUser(value: Row, member: Pick<HubMember, "id" | "username">) {
  if (text(value.id) !== member.id || !sameUser(text(value.username), member.username) || (value.state !== undefined && value.state !== "active") || (value.membership_state !== undefined && value.membership_state !== "active")) throw new Error(activeError());
}
async function groupAccess(c: HubAccess, group: string, member: Pick<HubMember, "id" | "username">): Promise<Omit<HubOrganizationMemberAccess, "organizationID" | "teamID">> {
  const effective = await optional(c, `${c.apiBase}/groups/${enc(group)}/members/all/${enc(member.id)}`);
  if (!effective) return { userID: member.id, username: member.username, role: "", effectiveRole: "", exists: false, direct: false, inherited: false, active: false, customRole: false };
  validateGitLabUser(effective, member);
  const direct = await optional(c, `${c.apiBase}/groups/${enc(group)}/members/${enc(member.id)}`);
  if (direct) validateGitLabUser(direct, member);
  const effectiveRole = text(effective.access_level), directRole = direct ? text(direct.access_level) : "";
  return { userID: member.id, username: member.username, role: directRole || effectiveRole, effectiveRole, exists: true, direct: !!direct, inherited: !direct || Number(effectiveRole) > Number(directRole), active: Number(effectiveRole) > 0, customRole: direct?.member_role_id != null || row(direct?.member_role).id != null };
}
async function organizationAccess(c: HubAccess, item: HubItem, member: Pick<HubMember, "id" | "username">): Promise<HubOrganizationMemberAccess> {
  if (c.target.provider === "gitlab") {
    const access = await groupAccess(c, item.id, member);
    if (!access.exists || !access.active) throw new Error(activeError());
    return { ...access, organizationID: item.id };
  }
  const membership = await optional(c, `${base(c, item)}/memberships/${enc(member.username)}`);
  const user = row(membership?.user);
  if (!membership || membership.state !== "active" || !sameUser(text(user.login), member.username) || text(user.id) !== member.id || !["member", "admin"].includes(text(membership.role))) throw new Error(activeError());
  return { organizationID: item.id, userID: member.id, username: member.username, role: text(membership.role), effectiveRole: text(membership.role), exists: true, direct: true, inherited: false, active: true, customRole: false };
}
async function teamAccess(c: HubAccess, item: HubItem, team: HubOrganizationTeam, member: Pick<HubMember, "id" | "username">): Promise<HubOrganizationMemberAccess> {
  if (c.target.provider === "gitlab") { const group = await hubRequest<Row>(c, `${c.apiBase}/groups/${enc(team.id)}`); if (text(group.parent_id) !== item.id) throw new Error(t("This subgroup no longer belongs to the selected organization. Refresh and review it again.")); return { ...await groupAccess(c, team.id, member), organizationID: item.id, teamID: team.id }; }
  if (!team.slug) throw new Error(t("The server did not provide this team's identifier."));
  const identity = await hubRequest<Row>(c, `${base(c, item)}/teams/${enc(team.slug)}`);
  if (text(identity.id) !== team.id || (identity.slug !== undefined && identity.slug !== team.slug)) throw new Error(t("This team changed on the server. Refresh and review it again."));
  const membership = await optional(c, `${base(c, item)}/teams/${enc(team.slug)}/memberships/${enc(member.username)}`);
  return { organizationID: item.id, teamID: team.id, userID: member.id, username: member.username, role: text(membership?.role), effectiveRole: text(membership?.role), exists: !!membership, direct: !!membership && membership.inherited !== true, inherited: membership?.inherited === true, active: membership?.state === "active", customRole: false };
}
const sameSnapshot = (a: HubOrganizationMemberAccess, b: HubOrganizationMemberAccess) => a.organizationID === b.organizationID && a.teamID === b.teamID && a.userID === b.userID && sameUser(a.username, b.username) && a.role === b.role && a.effectiveRole === b.effectiveRole && a.exists === b.exists && a.direct === b.direct && a.inherited === b.inherited && a.active === b.active && a.customRole === b.customRole;

/** Organization owners can inspect a loaded person's direct and inherited access. */
export async function readHubOrganizationMemberAccess(c: HubAccess, item: HubItem, member: Pick<HubMember, "id" | "username">): Promise<HubOrganizationMemberAccess> {
  validateTarget(c, member); await owner(c, item); return organizationAccess(c, item, member);
}
/** Team assignment always begins with confirmed active membership in its organization. */
export async function readHubOrganizationTeamAccess(c: HubAccess, item: HubItem, team: HubOrganizationTeam, member: Pick<HubMember, "id" | "username">): Promise<HubOrganizationMemberAccess> {
  validateTarget(c, member); await owner(c, item); if (c.target.provider === "gitlab") await owner(c, { ...item, id: team.id }); await organizationAccess(c, item, member); return teamAccess(c, item, team, member);
}
async function write(c: HubAccess, url: string, method: string, body: Row): Promise<Row> {
  try { return await hubRequest<Row>(c, url, method, body); }
  catch (error) {
    if (error instanceof HostingError && error.status >= 400 && error.status < 500) throw error;
    throw new HubUncertainWriteError(`${hubError(error, c.token)}\n\n${t("The server may have accepted the last change. Refresh and check the remote item before trying again.")}`);
  }
}
/** A fresh active membership check prevents GitHub's role upsert from creating an invitation. */
export async function setHubOrganizationMemberRole(c: HubAccess, item: HubItem, expected: HubOrganizationMemberAccess, role: string): Promise<string | null> {
  const member = { id: expected.userID, username: expected.username };
  if (expected.organizationID !== item.id || expected.teamID !== undefined) throw new Error(changedError());
  validateTarget(c, member); if (!roles(c, "organization").includes(role)) throw new Error(t("Choose a supported organization role."));
  await owner(c, item); const current = await organizationAccess(c, item, member);
  if (!sameSnapshot(expected, current)) throw new Error(changedError());
  if (!current.direct || current.inherited) throw new Error(inheritedError());
  if (current.customRole) throw new Error(t("Custom roles must be managed in the provider to preserve their permissions."));
  if (role === current.role) return null;
  ensureHubCurrent(c);
  const result = await write(c, c.target.provider === "github" ? `${base(c, item)}/memberships/${enc(member.username)}` : `${base(c, item)}/members/${enc(member.id)}`, "PUT", c.target.provider === "github" ? { role } : { access_level: Number(role) });
  if (c.target.provider === "github" && (result.state !== "active" || result.role !== role || !sameUser(text(row(result.user).login), member.username) || text(row(result.user).id) !== member.id)) throw new HubUncertainWriteError(t("The server may have accepted the last change. Refresh and check the remote item before trying again."));
  return permissionResult(c, result, member.id, role);
}
/** Assign only a confirmed existing organization person, after rechecking actor and target access. */
export async function setHubOrganizationTeamRole(c: HubAccess, item: HubItem, team: HubOrganizationTeam, expected: HubOrganizationMemberAccess, role: string): Promise<string | null> {
  const member = { id: expected.userID, username: expected.username };
  if (expected.organizationID !== item.id || expected.teamID !== team.id) throw new Error(changedError());
  validateTarget(c, member); if (!roles(c, "team").includes(role)) throw new Error(t("Choose a supported organization role."));
  await owner(c, item); if (c.target.provider === "gitlab") await owner(c, { ...item, id: team.id }); const parent = await organizationAccess(c, item, member); const current = await teamAccess(c, item, team, member);
  if (!sameSnapshot(expected, current)) throw new Error(changedError());
  if (current.inherited && (c.target.provider !== "gitlab" || current.direct || Number(role) <= Number(current.effectiveRole))) throw new Error(inheritedError());
  if (c.target.provider === "gitlab" && Number(role) < Number(parent.effectiveRole)) throw new Error(t("A subgroup role cannot be lower than the role inherited from its parent group."));
  if (current.customRole) throw new Error(t("Custom roles must be managed in the provider to preserve their permissions."));
  if (current.exists && !current.active) throw new Error(activeError());
  if (current.role === role) return null;
  ensureHubCurrent(c);
  if (c.target.provider === "github") { const result = await write(c, `${base(c, item)}/teams/${enc(team.slug)}/memberships/${enc(member.username)}`, "PUT", { role }); if (result.state !== "active" || result.role !== role) throw new HubUncertainWriteError(t("The server may have accepted the last change. Refresh and check the remote item before trying again.")); return null; }
  const result = await write(c, `${c.apiBase}/groups/${enc(team.id)}/members${current.direct ? `/${enc(member.id)}` : ""}`, current.direct ? "PUT" : "POST", { ...(current.direct ? {} : { user_id: Number(member.id) }), access_level: Number(role) });
  return permissionResult(c, result, member.id, role);
}

function permissionResult(c: HubAccess, result: Row, userID: string, role: string): string | null {
  if (c.target.provider !== "gitlab") return null;
  if (result.status === "error") throw new Error(t("The server rejected the access change: {0}", hubError(JSON.stringify(result.message ?? ""), c.token)));
  if (Object.keys(row(result.queued_users)).length > 0 || result.membership_state === "awaiting" || (!result.id && /\bqueued\b|awaiting (?:administrator )?approval/i.test(JSON.stringify(result.message ?? "")))) return t("The access request is awaiting administrator approval.");
  if (!result.id && result.message) throw new Error(t("The server rejected the access change: {0}", hubError(JSON.stringify(result.message), c.token)));
  if (text(result.id) !== userID || text(result.access_level) !== role) throw new HubUncertainWriteError(t("The server may have accepted the last change. Refresh and check the remote item before trying again."));
  return null;
}

/** Resolve one exact existing organization username; this path never invites a new person. */
export async function resolveHubOrganizationMember(c: HubAccess, item: HubItem, username: string): Promise<HubMember> {
  const login = username.trim().replace(/^@/, "");
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,98}$/.test(login)) throw new Error(t("Enter an existing organization member's username."));
  if (sameUser(login, c.me)) throw new Error(ownAccessError());
  await owner(c, item);
  let user: Row;
  if (c.target.provider === "github") {
    const membership = await optional(c, `${base(c, item)}/memberships/${enc(login)}`);
    user = row(membership?.user);
    if (!membership || membership.state !== "active" || !sameUser(text(user.login), login) || !text(user.id)) throw new Error(activeError());
  } else {
    const users = await hubRequest<unknown>(c, `${c.apiBase}/users?username=${enc(login)}`);
    if (!Array.isArray(users)) throw new Error(activeError());
    const matches = users.map(row).filter(value => sameUser(text(value.username), login));
    if (matches.length !== 1 || !text(matches[0].id)) throw new Error(activeError());
    user = matches[0];
  }
  const member: HubMember = { id: text(user.id), username: text(user.login ?? user.username), name: text(user.name) || login, role: t("Organization member"), avatarURL: null, url: "" };
  await organizationAccess(c, item, member);
  return member;
}
