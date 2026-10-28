import { t } from "@/shared/i18n";
import { ensureHubCurrent, hubRequest, hubSafeURL, hubError, hubMember, organizationAvatarURL, type HubAccess, type HubDetail, type HubItem, type HubMember, type HubRepository } from "./hub";
import type { HubOrganizationInvitation, HubOrganizationTeam } from "./organization-management";

export type HubOrganizationSection = "members" | "repositories" | "teams" | "invitations";
/** Preview page zero is superseded by the first full page, so no people are skipped. */
export interface HubOrganizationSectionState { page: number; more: boolean; loading: boolean; loaded: boolean; error?: string }
export interface HubOrganizationSectionPage { section: HubOrganizationSection; state: HubOrganizationSectionState; members: HubMember[]; repositories: HubRepository[]; teams: HubOrganizationTeam[]; invitations: HubOrganizationInvitation[] }
export interface HubOrganizationTeamPage { members: HubMember[]; state: HubOrganizationSectionState }
type Row = Record<string, unknown>;
const row = (value: unknown): Row => value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
const text = (value: unknown): string => typeof value === "string" ? value : typeof value === "number" ? String(value) : "";
const enc = encodeURIComponent;
const organizationBase = (c: HubAccess, item: HubItem) => `${c.apiBase}/${c.target.provider === "github" ? "orgs" : "groups"}/${enc(item.id)}`;
const previewSize = { members: 12, repositories: 6, teams: 6, invitations: 6 } as const;
export const organizationSectionState = (): HubOrganizationSectionState => ({ page: 0, more: false, loading: false, loaded: false });
export const organizationSections = (): Record<HubOrganizationSection, HubOrganizationSectionState> => ({ members: organizationSectionState(), repositories: organizationSectionState(), teams: organizationSectionState(), invitations: organizationSectionState() });
const list = async (c: HubAccess, url: string): Promise<Row[]> => { const values = await hubRequest<unknown>(c, url); if (!Array.isArray(values)) throw new Error(t("The server returned an unexpected response.")); return values.map(row); };
const loaded = (page: number, count: number, limit: number): HubOrganizationSectionState => ({ page, more: count === limit, loaded: true, loading: false });
export const organizationSectionError = (error: unknown, token?: string): string => hubError(error, token);

/** One optional batch enriches visible GitHub names without delaying unrelated sections on failure. */
async function people(c: HubAccess, values: Row[]): Promise<HubMember[]> {
  const members = values.map(value => { const member = hubMember(c, value); if (value.role === "maintainer") member.role = t("Maintainer"); return member; });
  if (c.target.provider !== "github" || !members.length) return members;
  const definitions = members.map((_member, index) => `$login${index}:String!`).join(",");
  const fields = members.map((_member, index) => `member${index}:user(login:$login${index}){name avatarUrl url}`).join(" ");
  const variables = Object.fromEntries(members.map((member, index) => [`login${index}`, member.username]));
  try {
    const result = await hubRequest<Row>(c, `${c.apiBase}/graphql`, "POST", { query: `query(${definitions}){${fields}}`, variables });
    const profiles = row(result.data);
    for (let index = 0; index < members.length; index++) {
      const profile = row(profiles[`member${index}`]);
      if (text(profile.name).trim()) members[index].name = text(profile.name).trim();
      if (organizationAvatarURL(c, profile.avatarUrl)) members[index].avatarURL = organizationAvatarURL(c, profile.avatarUrl);
      if (hubSafeURL(c, text(profile.url))) members[index].url = hubSafeURL(c, text(profile.url))!;
    }
  } catch { ensureHubCurrent(c); }
  return members;
}

/** Team slugs and subgroup IDs come from loaded server rows, never display names. */
export async function loadHubOrganizationTeamMembers(c: HubAccess, item: HubItem, team: HubOrganizationTeam, page: number): Promise<HubOrganizationTeamPage> {
  ensureHubCurrent(c);
  const limit = page === 0 ? 6 : 30;
  if (c.target.provider === "github" && !team.slug) throw new Error(t("The server did not provide this team's identifier."));
  const url = c.target.provider === "github" ? `${organizationBase(c, item)}/teams/${enc(team.slug)}/members?role=all&per_page=${limit}&page=${Math.max(1, page)}` : `${c.apiBase}/groups/${enc(team.id)}/members/all?per_page=${limit}&page=${Math.max(1, page)}`;
  const values = await list(c, url);
  const members = await people(c, values);
  ensureHubCurrent(c);
  return { members, state: loaded(page, values.length, limit) };
}

/** Each dashboard section has its own request, page and error boundary. */
export async function loadHubOrganizationSection(c: HubAccess, item: HubItem, section: HubOrganizationSection, page: number, canInvite: boolean): Promise<HubOrganizationSectionPage> {
  ensureHubCurrent(c);
  if (section === "invitations" && !canInvite) throw new Error(t("This account cannot access this section. Check organization ownership, token permissions and server policy."));
  const github = c.target.provider === "github", effectivePage = section === "teams" ? Math.max(1, page) : page, limit = section === "teams" ? 6 : page === 0 ? previewSize[section] : 30;
  const path = section === "members" ? github ? "members" : "members/all" : section === "repositories" ? github ? "repos" : "projects" : section === "teams" ? github ? "teams" : "subgroups" : "invitations";
  const query = `per_page=${limit}&page=${Math.max(1, effectivePage)}${section === "repositories" ? github ? "&sort=updated" : "&include_subgroups=true&order_by=last_activity_at" : section === "teams" && !github ? "&all_available=true" : ""}`;
  const values = await list(c, `${organizationBase(c, item)}/${path}?${query}`);
  const result: HubOrganizationSectionPage = { section, state: loaded(effectivePage, values.length, limit), members: [], repositories: [], teams: [], invitations: [] };
  if (section === "members") result.members = await people(c, values);
  else if (section === "repositories") result.repositories = values.map(value => ({ id: text(value.id), name: text(value.full_name ?? value.path_with_namespace), description: text(value.description), cloneURL: text(value.clone_url ?? value.http_url_to_repo), url: hubSafeURL(c, text(value.html_url ?? value.web_url)) ?? "" }));
  else if (section === "invitations") result.invitations = values.map(value => {
    const email = text(value.email ?? value.invite_email);
    return { id: github ? text(value.id) : email, email, name: text(value.login) || email, role: invitationRole(text(value.role ?? value.access_level)), createdAt: text(value.created_at), expiresAt: text(value.expires_at) };
  });
  else {
    result.teams = values.map(value => ({ id: text(value.id), slug: text(value.slug), name: text(value.name), description: text(value.description), url: hubSafeURL(c, text(value.html_url ?? value.web_url)) ?? "", privacy: text(value.privacy ?? value.visibility), members: [], memberState: organizationSectionState() }));
    // At most six teams are hydrated automatically; remaining cards load people on demand.
    await Promise.allSettled(result.teams.slice(0, 6).map(async team => {
      try { const people = await loadHubOrganizationTeamMembers(c, item, team, 0); team.members = people.members; team.memberState = people.state; }
      catch (error) { ensureHubCurrent(c); team.memberState = { ...organizationSectionState(), loaded: true, error: organizationSectionError(error, c.token) }; }
    }));
  }
  ensureHubCurrent(c);
  return result;
}

const merge = <T extends { id: string }>(old: T[], next: T[]): T[] => [...old, ...next.filter(value => !old.some(existing => existing.id === value.id))];
/** Append independently without dropping other dashboard sections or expanded team people. */
export function applyHubOrganizationSection(detail: HubDetail, page: HubOrganizationSectionPage, append: boolean): HubDetail {
  if (!detail.organization) return detail;
  const organization = { ...detail.organization, sections: { ...detail.organization.sections, [page.section]: page.state } };
  const result = { ...detail, organization };
  if (page.section === "members") result.members = append ? merge(detail.members, page.members) : page.members;
  else if (page.section === "repositories") result.repositories = append ? merge(detail.repositories, page.repositories) : page.repositories;
  else if (page.section === "invitations") organization.invitations = append ? merge(organization.invitations, page.invitations) : page.invitations;
  else organization.teams = append ? merge(organization.teams, page.teams) : page.teams;
  return result;
}

/** Preview every organization section together; one inaccessible list never hides successful lists. */
export async function loadHubOrganizationDashboard(c: HubAccess, detail: HubDetail): Promise<HubDetail> {
  const sections: HubOrganizationSection[] = ["members", "teams", "repositories", "invitations"];
  const results = await Promise.allSettled(sections.map(section => loadHubOrganizationSection(c, detail.item, section, 0, detail.organization?.info.canInvite ?? false)));
  ensureHubCurrent(c);
  let result = detail;
  results.forEach((value, index) => {
    const section = sections[index];
    if (value.status === "fulfilled") result = applyHubOrganizationSection(result, value.value, false);
    else if (result.organization) result.organization.sections[section] = { ...organizationSectionState(), loaded: true, error: organizationSectionError(value.reason, c.token) };
  });
  return result;
}

const invitationRole = (role: string): string => ({ admin: t("Owner"), direct_member: t("Member"), member: t("Member"), billing_manager: t("Billing manager"), "10": t("Guest"), "15": t("Planner"), "20": t("Reporter"), "30": t("Developer"), "40": t("Maintainer"), "50": t("Owner") })[role] ?? role;
