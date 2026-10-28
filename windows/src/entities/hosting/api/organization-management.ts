import { t } from "@/shared/i18n";
import { HostingError } from "./hosting";
import { ensureHubCurrent, hubRequest, hubRawRequest, hubSafeURL, organizationAvatarURL, hubError, HubUncertainWriteError, type HubAccess, type HubDetail, type HubItem } from "./hub";

type ObjectValue = Record<string, unknown>;
export type HubOrganizationTab = "overview" | "repositories" | "members" | "teams" | "invitations";
export interface HubOrganizationTeam { id: string; name: string; description: string; url: string; privacy: string }
export interface HubOrganizationInvitation { id: string; email: string; name: string; role: string; createdAt: string; expiresAt: string }
export interface HubOrganizationInfo { role: string; canInvite: boolean; publicRepositories?: number; privateRepositories?: number; location: string; website: string; visibility: string; notice?: string }
export interface HubOrganizationData { info: HubOrganizationInfo; teams: HubOrganizationTeam[]; invitations: HubOrganizationInvitation[] }
export interface HubOrganizationInviteInput { email: string; role: string; expiresAt: string }
export interface HubOrganizationLink { title: string; url: string }
const object = (value: unknown): ObjectValue => value && typeof value === "object" && !Array.isArray(value) ? value as ObjectValue : {};
const text = (value: unknown): string => typeof value === "string" ? value : typeof value === "number" ? String(value) : "";
const number = (value: unknown): number | undefined => typeof value === "number" && Number.isFinite(value) ? value : undefined;
const enc = encodeURIComponent;
const base = (c: HubAccess, item: HubItem) => `${c.apiBase}/${c.target.provider === "github" ? "orgs" : "groups"}/${enc(item.id)}`;
const permissionNotice = () => t("This account cannot access this section. Check organization ownership, token permissions and server policy.");
const roleName = (role: string): string => ({ admin: t("Owner"), direct_member: t("Member"), member: t("Member"), billing_manager: t("Billing manager"), "10": t("Guest"), "15": t("Planner"), "20": t("Reporter"), "30": t("Developer"), "40": t("Maintainer"), "50": t("Owner") })[role] ?? role;

/** Organization roles only enable writes after the server confirms current ownership. */
async function permissions(c: HubAccess, item: HubItem, profile: ObjectValue): Promise<HubOrganizationInfo> {
  let role = t("Unknown"), canInvite = false, notice: string | undefined;
  if (c.target.provider === "github") {
    try {
      const membership = await hubRequest<ObjectValue>(c, `${c.apiBase}/user/memberships/orgs/${enc(item.id)}`);
      const active = membership.state === "active";
      role = active ? roleName(text(membership.role)) : t("Pending membership");
      canInvite = active && membership.role === "admin";
    } catch (error) { ensureHubCurrent(c); if (error instanceof HostingError && [403, 404].includes(error.status)) notice = permissionNotice(); else throw error; }
  } else {
    try {
      const user = await hubRequest<ObjectValue>(c, `${c.apiBase}/user`);
      if (!text(user.id) || text(user.username).toLowerCase() !== c.me.toLowerCase()) throw new Error(t("The repository or account changed. Reopen this action."));
      const membership = await hubRequest<ObjectValue>(c, `${base(c, item)}/members/all/${enc(text(user.id))}`);
      const access = number(membership.access_level) ?? 0;
      if (access > 0) role = roleName(String(access));
      canInvite = access === 50;
    } catch (error) { ensureHubCurrent(c); if (error instanceof HostingError && [403, 404].includes(error.status)) notice = permissionNotice(); else throw error; }
  }
  return { role, canInvite, publicRepositories: number(profile.public_repos), privateRepositories: number(profile.total_private_repos), location: text(profile.location), website: text(profile.blog), visibility: text(profile.visibility), notice };
}

/** Load one bounded organization section while keeping its profile available on permission failures. */
export async function hubOrganizationDetail(c: HubAccess, item: HubItem, page: number, tab: HubOrganizationTab): Promise<HubDetail> {
  const profile = await hubRequest<ObjectValue>(c, base(c, item));
  const info = await permissions(c, item, profile);
  const detail: HubDetail = { item: { ...item, title: text(profile.name) || item.title, body: text(profile.description), data: profile, avatarURL: profile.avatar_url === undefined ? item.avatarURL : organizationAvatarURL(c, profile.avatar_url), url: hubSafeURL(c, text(profile.html_url ?? profile.web_url)) ?? item.url }, members: [], repositories: [], assets: [], fields: [], rows: [], more: false, organization: { info, teams: [], invitations: [] } };
  const data = detail.organization!;
  if (tab === "overview") return detail;
  if (tab === "invitations" && !info.canInvite) { detail.notice = permissionNotice(); return detail; }
  const path = tab === "teams" ? c.target.provider === "github" ? "teams" : "subgroups" : "invitations";
  try {
    const values = await hubRequest<unknown>(c, `${base(c, item)}/${path}?per_page=30&page=${Math.max(1, page)}${c.target.provider === "gitlab" && tab === "teams" ? "&all_available=true" : ""}`);
    if (!Array.isArray(values)) throw new Error(t("The server returned an unexpected response."));
    detail.more = values.length === 30;
    if (tab === "teams") data.teams = values.map(value => {
      const row = object(value);
      return { id: text(row.id), name: text(row.name), description: text(row.description), url: hubSafeURL(c, text(row.html_url ?? row.web_url)) ?? "", privacy: text(row.privacy ?? row.visibility) };
    });
    else data.invitations = values.map(value => {
      const row = object(value), email = text(row.email ?? row.invite_email);
      return { id: c.target.provider === "github" ? text(row.id) : email, email, name: text(row.login) || email, role: roleName(text(row.role ?? row.access_level)), createdAt: text(row.created_at), expiresAt: text(row.expires_at) };
    });
  } catch (error) {
    ensureHubCurrent(c);
    if (error instanceof HostingError && [403, 404].includes(error.status)) detail.notice = permissionNotice();
    else throw error;
  }
  return detail;
}

const localDay = () => { const today = new Date(); return `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, "0")}-${String(today.getDate()).padStart(2, "0")}`; };

/** Mirrored by macOS organization invite validation. */
export function hubOrganizationInviteError(provider: "github" | "gitlab", input: HubOrganizationInviteInput): string | null {
  if (/[,;]/.test(input.email) || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(input.email.trim()) || input.email.trim().length > 254) return t("Enter a valid email address.");
  const roles = provider === "github" ? ["direct_member", "admin", "billing_manager"] : ["10", "15", "20", "30", "40", "50"];
  if (!roles.includes(input.role)) return t("Choose a supported organization role.");
  if (provider === "github" && input.expiresAt) return t("GitHub invitation expiration is managed by GitHub.");
  if (input.expiresAt) {
    const date = new Date(`${input.expiresAt}T00:00:00Z`);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(input.expiresAt) || !Number.isFinite(date.getTime()) || date.toISOString().slice(0, 10) !== input.expiresAt || input.expiresAt < localDay()) return t("Choose today or a future expiration date.");
  }
  return null;
}

async function requireOwner(c: HubAccess, item: HubItem) {
  const profile = await hubRequest<ObjectValue>(c, base(c, item));
  const info = await permissions(c, item, profile);
  if (!info.canInvite) throw new Error(permissionNotice());
  ensureHubCurrent(c);
}

/** Review a single recipient before calling this write; never retry an ambiguous response. */
export async function inviteHubOrganizationMember(c: HubAccess, item: HubItem, input: HubOrganizationInviteInput): Promise<string | null> {
  ensureHubCurrent(c);
  const error = hubOrganizationInviteError(c.target.provider, input);
  if (error) throw new Error(error);
  await requireOwner(c, item);
  let result: ObjectValue;
  try {
    result = await hubRequest<ObjectValue>(c, `${base(c, item)}/invitations`, "POST", c.target.provider === "github" ? { email: input.email.trim(), role: input.role } : { email: input.email.trim(), access_level: Number(input.role), ...(input.expiresAt ? { expires_at: input.expiresAt } : {}) });
  } catch (error) {
    if (error instanceof HostingError && error.status >= 400 && error.status < 500) throw error;
    throw new HubUncertainWriteError(`${hubError(error, c.token)}\n\n${t("The server may have accepted the last change. Refresh and check the remote item before trying again.")}`);
  }
  if (c.target.provider === "gitlab") {
    if (result.status === "error") throw new Error(t("The server rejected the invitation: {0}", hubError(JSON.stringify(result.message ?? ""), c.token)));
    if (Object.keys(object(result.queued_users)).length > 0) return t("The invitation is awaiting administrator approval.");
    if (result.status !== "success") throw new HubUncertainWriteError(t("The server may have accepted the last change. Refresh and check the remote item before trying again."));
  }
  return null;
}

/** Only a loaded invitation can be cancelled, after a fresh ownership check. */
export async function cancelHubOrganizationInvitation(c: HubAccess, detail: HubDetail, invitation: HubOrganizationInvitation): Promise<void> {
  ensureHubCurrent(c);
  const loaded = detail.organization?.invitations.find(value => value.id === invitation.id);
  if (!loaded || !loaded.id) throw new Error(t("Select a loaded invitation before cancelling it."));
  await requireOwner(c, detail.item);
  try { await hubRawRequest(c, `${base(c, detail.item)}/invitations/${enc(loaded.id)}`, "DELETE"); }
  catch (error) {
    if (error instanceof HostingError && error.status >= 400 && error.status < 500) throw error;
    throw new HubUncertainWriteError(`${hubError(error, c.token)}\n\n${t("The server may have accepted the last change. Refresh and check the remote item before trying again.")}`);
  }
}

/** Provider controls remain available without granting additional application privileges. */
export function hubOrganizationLinks(c: { target: Pick<HubAccess["target"], "provider" | "host"> }, item: HubItem): HubOrganizationLink[] {
  const github = c.target.provider === "github";
  let origin: URL;
  try { origin = new URL(item.url); if (origin.hostname.toLowerCase() !== c.target.host.toLowerCase() || !hubSafeURL(c, item.url)) return []; } catch { return []; }
  const path = `/groups${origin.pathname.replace(/\/$/, "")}`;
  const org = enc(item.id);
  const links: [string, string][] = github ? [[t("People"), `/orgs/${org}/people`], [t("Teams"), `/orgs/${org}/teams`], [t("Projects"), `/orgs/${org}/projects`], [t("Packages"), `/orgs/${org}/packages`], [t("Settings"), `/organizations/${org}/settings/profile`], [t("Security"), `/organizations/${org}/settings/security_analysis`], [t("Audit log"), `/organizations/${org}/settings/audit-log`], [t("Billing"), `/organizations/${org}/settings/billing`]] : [[t("Members"), `${path}/-/group_members`], [t("Subgroups"), `${path}/-/children`], [t("Issue boards"), `${path}/-/boards`], [t("Packages"), `${path}/-/packages`], [t("Settings"), `${path}/-/edit`], [t("Security"), `${path}/-/security/dashboard`], [t("Audit log"), `${path}/-/audit_events`]];
  return links.map(([title, suffix]) => ({ title, url: new URL(suffix, origin.origin).href })).filter(link => !!hubSafeURL(c, link.url));
}
