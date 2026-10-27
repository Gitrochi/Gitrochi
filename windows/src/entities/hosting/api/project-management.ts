import { t } from "@/shared/i18n";
import { HostingError } from "./hosting";
import { localProjects } from "../model/local-projects";
import { ensureHubCurrent, hubError, hubGraphql, hubRequest, hubUsesLocal, HubProjectActionDeniedError, HubProjectPermissionError, HubUncertainWriteError, type HubAccess, type HubDetail, type HubItem, type HubProjectField } from "./hub";

/** Windows: mirrors the checked ProjectV2 management contract in ProjectManagement.swift. */
export type HubProjectPlanTier = "free" | "pro" | "team" | "enterprise" | "unknown";
export type HubProjectPlanSource = "authenticatedUser" | "organization" | "unavailable";
export type HubProjectOwnerKind = "user" | "organization" | "unknown";
export interface HubProjectPlan { tier: HubProjectPlanTier; rawName: string | null; source: HubProjectPlanSource }
export interface HubProjectCreationCapabilities {
  viewerLogin: string; viewerVerified: boolean; ownerLogin: string; ownerID: string; ownerKind: HubProjectOwnerKind;
  accountPlan: HubProjectPlan; ownerPlan: HubProjectPlan; canCreate: boolean | null; canPublish: boolean | null;
  limits: { fields: number; autoAddWorkflows: number | null }; notice: string | null;
}

export interface HubProjectSettingsInput { title: string; shortDescription: string; readme: string; public: boolean; closed: boolean }
export type HubProjectOptionColor = "BLUE" | "GRAY" | "GREEN" | "ORANGE" | "PINK" | "PURPLE" | "RED" | "YELLOW";
export interface HubProjectFieldOptionInput { id?: string; name: string; color?: HubProjectOptionColor; description?: string }
export interface HubProjectFieldInput { name: string; kind: "text" | "number" | "date" | "singleSelect"; options?: HubProjectFieldOptionInput[] }
export type HubProjectViewLayout = "BOARD_LAYOUT" | "TABLE_LAYOUT" | "ROADMAP_LAYOUT";
export interface HubProjectView { id: string; name: string; number?: number; updatedAt?: string; layout: HubProjectViewLayout; filter: string; visibleFieldIDs: string[]; groupFieldIDs: string[]; sortFields: { fieldID: string; direction: "ASC" | "DESC" }[] }
export interface HubProjectViewInput { name: string; layout: HubProjectViewLayout; filter: string; visibleFieldIDs: string[] }
export interface HubProjectViewPage { views: HubProjectView[]; more: boolean; cursor?: string }

type ObjectValue = Record<string, unknown>;
const object = (value: unknown): ObjectValue => value && typeof value === "object" ? value as ObjectValue : {};
const objects = (value: unknown): ObjectValue[] => Array.isArray(value) ? value.filter((item): item is ObjectValue => !!item && typeof item === "object") : [];
const text = (value: unknown) => typeof value === "string" ? value : "";
const nodes = (value: unknown) => objects(object(value).nodes);
const fieldIDFragment = "... on ProjectV2FieldCommon{id}";
const fieldFragment = "... on ProjectV2FieldCommon{id name dataType} ... on ProjectV2SingleSelectField{id name options{id name color description}}";
const viewFragment = `id name number updatedAt layout filter project{id} configuration{visibleFields(first:100){nodes{${fieldIDFragment}} pageInfo{hasNextPage}}} groupByFields(first:100){nodes{${fieldIDFragment}} pageInfo{hasNextPage}} sortByFields(first:100){nodes{direction field{${fieldIDFragment}}} pageInfo{hasNextPage}}`;
const projectFragment = "id number title shortDescription readme public closed url updatedAt";
const conflict = () => new Error(t("This item changed on the server. Refresh before saving."));
const invalid = () => new Error(t("Enter a valid project name and field configuration."));
const colors = new Set(["BLUE", "GRAY", "GREEN", "ORANGE", "PINK", "PURPLE", "RED", "YELLOW"]);
const kinds = { text: "TEXT", number: "NUMBER", date: "DATE", singleSelect: "SINGLE_SELECT" } as const;

function github(c: HubAccess, detail?: HubDetail) {
  ensureHubCurrent(c);
  if (detail && hubUsesLocal(c, detail.item)) throw new Error(t("This action requires a GitHub project."));
  if (c.local || c.target.provider !== "github" || detail && !detail.item.id) throw new Error(t("This action requires a GitHub project."));
}
function name(value: string) { if (!value.trim()) throw invalid(); return value.trim(); }
async function creation<T>(c: HubAccess, action: () => Promise<T>): Promise<T> {
  try { return await action(); }
  catch (error) {
    if (error instanceof HostingError && error.status === 403) throw new HubProjectActionDeniedError(hubError(error, c.token));
    if (error instanceof HostingError && error.status >= 400 && error.status < 500 || error instanceof HubProjectPermissionError || error instanceof HubProjectActionDeniedError || error instanceof HubUncertainWriteError) throw error;
    throw new HubUncertainWriteError(`${hubError(error, c.token)}\n\n${t("The server may have accepted the last change. Refresh and check the remote item before trying again.")}`);
  }
}
function item(value: ObjectValue): HubItem {
  if (!text(value.id)) throw new Error(t("The server returned an unexpected response."));
  return { id: text(value.id), title: text(value.title), subtitle: `#${value.number ?? ""}${value.closed ? " · closed" : ""}`, body: text(value.shortDescription), url: text(value.url), data: value };
}

/** Missing or legacy billing names remain unknown; membership and server host do not imply a paid plan. */
export function hubProjectPlanTier(rawName: string | null, ownerKind: HubProjectOwnerKind): HubProjectPlanTier {
  const value = (rawName ?? "").trim().toLowerCase().replace(/^github /, "").replace(/[- ]/g, "_");
  if (value === "free") return "free";
  if (ownerKind === "user" && value === "pro") return "pro";
  if (ownerKind === "organization") { if (value === "team") return "team"; if (["enterprise", "enterprise_cloud", "enterprise_server"].includes(value)) return "enterprise"; }
  return "unknown";
}
function plan(rawName: unknown, source: HubProjectPlanSource, ownerKind: HubProjectOwnerKind): HubProjectPlan {
  const raw = text(rawName).trim(); return { tier: hubProjectPlanTier(raw || null, ownerKind), rawName: raw || null, source: raw ? source : "unavailable" };
}
/** Projects are available on Free; plan probes never pretend to prove Projects write permission. */
export async function inspectHubProjectCreationCapabilities(c: HubAccess): Promise<HubProjectCreationCapabilities> {
  github(c); const requestedOwner = c.target.path.split("/")[0] || c.me;
  let viewer: ObjectValue = {}, owner: ObjectValue = {};
  try { viewer = await hubRequest<ObjectValue>(c, `${c.apiBase}/user`); } catch { ensureHubCurrent(c); }
  try { const data = await hubGraphql<ObjectValue>(c, "query($owner:String!){repositoryOwner(login:$owner){__typename id login}}", { owner: requestedOwner }); owner = object(data.repositoryOwner); } catch { ensureHubCurrent(c); }
  const viewerLogin = text(viewer.login), viewerVerified = !!viewerLogin && viewerLogin.toLowerCase() === c.me.toLowerCase(), ownerLogin = text(owner.login) || requestedOwner;
  const ownerKind: HubProjectOwnerKind = owner.__typename === "Organization" ? "organization" : owner.__typename === "User" ? "user" : "unknown";
  const unknown: HubProjectPlan = { tier: "unknown", rawName: null, source: "unavailable" }, accountPlan = viewerVerified ? plan(object(viewer.plan).name, "authenticatedUser", "user") : unknown;
  let ownerPlan = ownerKind === "user" && viewerVerified && ownerLogin.toLowerCase() === viewerLogin.toLowerCase() ? accountPlan : unknown;
  if (ownerKind === "organization" && text(owner.id)) {
    try { const organization = await hubRequest<ObjectValue>(c, `${c.apiBase}/orgs/${encodeURIComponent(ownerLogin)}`); if (text(organization.login).toLowerCase() === ownerLogin.toLowerCase()) ownerPlan = plan(object(organization.plan).name, "organization", "organization"); } catch { ensureHubCurrent(c); }
  }
  const autoAddWorkflows = ({ free: 1, pro: 5, team: 5, enterprise: 20, unknown: null } as const)[ownerPlan.tier];
  let notice = t("Projects are available on GitHub Free. GitHub verifies creation and publishing permissions when you save.");
  if (!viewerVerified) notice += `\n${t("The connected account could not be verified. Refresh account access before creating a GitHub project.")}`;
  if (ownerPlan.tier === "unknown") notice += `\n${t("GitHub did not expose this owner's plan. Plan-dependent limits are unknown.")}`;
  ensureHubCurrent(c);
  return { viewerLogin: viewerLogin || c.me, viewerVerified, ownerLogin, ownerID: text(owner.id), ownerKind, accountPlan, ownerPlan, canCreate: null, canPublish: null, limits: { fields: 50, autoAddWorkflows }, notice };
}

/** Creates under the captured scope, resolving its owner and optional repository on the same API. */
export async function createHubProject(c: HubAccess, title: string, isPublic = false): Promise<HubItem> {
  github(c); const cleanTitle = name(title), [owner, repository] = c.target.path.split("/");
  const personal = repository === "workspace";
  const result = await hubGraphql<ObjectValue>(c, personal ? "query($owner:String!){repositoryOwner(login:$owner){id}}" : "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){id owner{id}}}", personal ? { owner } : { owner, name: repository });
  const source = object(result.repository), ownerID = text((personal ? object(result.repositoryOwner) : object(source.owner)).id);
  if (!ownerID || !personal && !text(source.id)) throw new Error(t("Projects are unavailable for this repository owner."));
  return creation(c, async () => {
    const response = await hubGraphql<ObjectValue>(c, `mutation($input:CreateProjectV2Input!){createProjectV2(input:$input){projectV2{${projectFragment}}}}`, { input: { ownerId: ownerID, title: cleanTitle, ...(!personal ? { repositoryId: source.id } : {}) } });
    const created = item(object(object(response.createProjectV2).projectV2));
    if (created.data.public !== false) throw new HubUncertainWriteError(t("GitHub returned unexpected project visibility. Refresh and check the created project before continuing."), created);
    if (!isPublic) return created;
    try {
      const published = await hubGraphql<ObjectValue>(c, `mutation($input:UpdateProjectV2Input!){updateProjectV2(input:$input){projectV2{${projectFragment}}}}`, { input: { projectId: created.id, public: true } });
      const result = item(object(object(published.updateProjectV2).projectV2));
      if (result.id !== created.id || result.data.public !== true) throw new Error(t("The server returned an unexpected response."));
      return result;
    } catch (error) {
      throw new HubUncertainWriteError(`${t("The private project was created, but publishing was not confirmed. Refresh projects before trying again.")}\n\n${hubError(error, c.token)}`, created);
    }
  });
}

/** Rejects stale metadata before changing the project's identity, visibility or lifecycle. */
export async function saveHubProjectSettings(c: HubAccess, detail: HubDetail, input: HubProjectSettingsInput): Promise<void> {
  if (hubUsesLocal(c, detail.item)) { await localProjects.saveProject(detail, input.title, input.shortDescription); ensureHubCurrent(c); return; }
  github(c, detail); const title = name(input.title);
  const response = await hubGraphql<ObjectValue>(c, `query($id:ID!){node(id:$id){... on ProjectV2{${projectFragment}}}}`, { id: detail.item.id });
  const fresh = object(response.node), previous = detail.item;
  if (fresh.id !== previous.id || fresh.title !== previous.title || text(fresh.shortDescription) !== previous.body || ["readme", "public", "closed", "updatedAt"].some(key => previous.data[key] !== undefined && fresh[key] !== previous.data[key])) throw conflict();
  await hubGraphql(c, "mutation($input:UpdateProjectV2Input!){updateProjectV2(input:$input){projectV2{id}}}", { input: { projectId: previous.id, title, shortDescription: input.shortDescription, readme: input.readme, public: input.public, closed: input.closed } });
}

function loadedField(detail: HubDetail, field: HubProjectField): HubProjectField {
  const actual = detail.fields.find(candidate => candidate.id === field.id);
  if (!actual || !Object.hasOwn(kinds, actual.kind ?? "")) throw new Error(t("Select a loaded custom project field."));
  return actual;
}
async function freshField(c: HubAccess, detail: HubDetail, field: HubProjectField): Promise<ObjectValue> {
  const response = await hubGraphql<ObjectValue>(c, `query($id:ID!){node(id:$id){... on ProjectV2{id fields(first:100){nodes{${fieldFragment}}}}}}`, { id: detail.item.id });
  const project = object(response.node), fresh = nodes(project.fields).find(value => value.id === field.id);
  if (project.id !== detail.item.id || !fresh || fresh.name !== field.name || field.kind === "singleSelect" && JSON.stringify(objects(fresh.options).map(value => [value.id, value.name])) !== JSON.stringify(field.options.map(value => [value.id, value.name])) || field.kind !== "singleSelect" && fresh.dataType !== kinds[field.kind as keyof typeof kinds]) throw conflict();
  return fresh;
}
function fieldOptions(input: HubProjectFieldInput, current?: ObjectValue): ObjectValue[] | undefined {
  if (input.kind !== "singleSelect") { if (input.options?.length) throw invalid(); return undefined; }
  const options = input.options ?? [], known = objects(current?.options);
  if (!options.length || new Set(options.map(value => name(value.name))).size !== options.length) throw invalid();
  const ids = options.flatMap(value => value.id ? [value.id] : []);
  if (new Set(ids).size !== ids.length) throw invalid();
  return options.map(value => {
    const existing = value.id ? known.find(option => option.id === value.id) : undefined;
    if (value.id && !existing || value.color && !colors.has(value.color)) throw invalid();
    return { ...(value.id ? { id: value.id } : {}), name: name(value.name), color: value.color ?? (text(existing?.color) || "GRAY"), description: value.description ?? text(existing?.description) };
  });
}

/** Existing option IDs are retained so renames do not clear task values. Field types cannot change. */
export async function saveHubProjectCustomField(c: HubAccess, detail: HubDetail, input: HubProjectFieldInput, previous?: HubProjectField): Promise<void> {
  github(c, detail); const cleanName = name(input.name);
  if (!Object.hasOwn(kinds, input.kind)) throw invalid();
  if (!previous) {
    const options = fieldOptions(input);
    await creation(c, () => hubGraphql(c, `mutation($input:CreateProjectV2FieldInput!){createProjectV2Field(input:$input){projectV2Field{${fieldIDFragment}}}}`, { input: { projectId: detail.item.id, name: cleanName, dataType: kinds[input.kind], ...(options ? { singleSelectOptions: options } : {}) } }));
    return;
  }
  const actual = loadedField(detail, previous);
  if (actual.kind !== input.kind) throw invalid();
  const fresh = await freshField(c, detail, actual), options = fieldOptions(input, fresh);
  await hubGraphql(c, `mutation($input:UpdateProjectV2FieldInput!){updateProjectV2Field(input:$input){projectV2Field{${fieldIDFragment}}}}`, { input: { fieldId: actual.id, name: cleanName, ...(options ? { singleSelectOptions: options } : {}) } });
}

/** Deletes only a loaded custom field after checking its current server identity. */
export async function deleteHubProjectCustomField(c: HubAccess, detail: HubDetail, field: HubProjectField): Promise<void> {
  github(c, detail); const actual = loadedField(detail, field); await freshField(c, detail, actual);
  await hubGraphql(c, `mutation($input:DeleteProjectV2FieldInput!){deleteProjectV2Field(input:$input){projectV2Field{${fieldIDFragment}}}}`, { input: { fieldId: actual.id } });
}

function parseView(value: ObjectValue): HubProjectView {
  const visible = object(object(value.configuration).visibleFields), group = object(value.groupByFields), sort = object(value.sortByFields);
  if (!text(value.id) || !["BOARD_LAYOUT", "TABLE_LAYOUT", "ROADMAP_LAYOUT"].includes(text(value.layout)) || [visible, group, sort].some(connection => object(connection.pageInfo).hasNextPage === true)) throw new Error(t("The server returned an unexpected response."));
  const visibleFieldIDs = nodes(visible).map(field => text(field.id)), groupFieldIDs = nodes(group).map(field => text(field.id)), sortFields = nodes(sort).map(entry => ({ fieldID: text(object(entry.field).id), direction: entry.direction === "DESC" ? "DESC" as const : "ASC" as const }));
  if ([...visibleFieldIDs, ...groupFieldIDs, ...sortFields.map(field => field.fieldID)].some(id => !id)) throw new Error(t("The server returned an unexpected response."));
  return { id: text(value.id), name: text(value.name), number: typeof value.number === "number" ? value.number : undefined, updatedAt: text(value.updatedAt) || undefined, layout: value.layout as HubProjectViewLayout, filter: text(value.filter), visibleFieldIDs, groupFieldIDs, sortFields };
}

/** Returns the server's shared views with pagination and their read-only grouping/sort configuration. */
export async function hubProjectViews(c: HubAccess, detail: HubDetail, cursor?: string): Promise<HubProjectViewPage> {
  github(c, detail);
  const response = await hubGraphql<ObjectValue>(c, `query($id:ID!,$cursor:String){node(id:$id){... on ProjectV2{id views(first:30,after:$cursor){nodes{${viewFragment}} pageInfo{hasNextPage endCursor}}}}}`, { id: detail.item.id, cursor: cursor ?? null });
  const project = object(response.node), connection = object(project.views), page = object(connection.pageInfo);
  if (project.id !== detail.item.id) throw new Error(t("Project is unavailable or this account cannot access it."));
  return { views: nodes(connection).map(parseView), more: page.hasNextPage === true, cursor: text(page.endCursor) || undefined };
}
async function freshView(c: HubAccess, detail: HubDetail, previous: HubProjectView) {
  const response = await hubGraphql<ObjectValue>(c, `query($id:ID!){node(id:$id){... on ProjectV2View{${viewFragment}}}}`, { id: previous.id });
  const fresh = object(response.node);
  if (object(fresh.project).id !== detail.item.id) throw conflict();
  const current = parseView(fresh);
  if (current.id !== previous.id || current.name !== previous.name || current.number !== previous.number || current.updatedAt !== previous.updatedAt || current.layout !== previous.layout || current.filter !== previous.filter || JSON.stringify(current.visibleFieldIDs) !== JSON.stringify(previous.visibleFieldIDs) || JSON.stringify(current.groupFieldIDs) !== JSON.stringify(previous.groupFieldIDs) || JSON.stringify(current.sortFields.map(value => [value.fieldID, value.direction])) !== JSON.stringify(previous.sortFields.map(value => [value.fieldID, value.direction]))) throw conflict();
}

/** The official API permits name/layout/filter/visible fields; grouping and sorting remain unchanged. */
export async function saveHubProjectView(c: HubAccess, detail: HubDetail, input: HubProjectViewInput, previous?: HubProjectView): Promise<void> {
  github(c, detail); const cleanName = name(input.name);
  if (!["BOARD_LAYOUT", "TABLE_LAYOUT", "ROADMAP_LAYOUT"].includes(input.layout) || new Set(input.visibleFieldIDs).size !== input.visibleFieldIDs.length || input.visibleFieldIDs.some(id => !detail.fields.some(field => field.id === id))) throw invalid();
  const configuration = { visibleFieldIds: input.visibleFieldIDs };
  if (previous) {
    await freshView(c, detail, previous);
    await hubGraphql(c, "mutation($input:UpdateProjectV2ViewInput!){updateProjectV2View(input:$input){projectV2View{id}}}", { input: { viewId: previous.id, name: cleanName, layout: input.layout, filter: input.filter, configuration } });
    return;
  }
  await creation(c, async () => {
    const response = await hubGraphql<ObjectValue>(c, "mutation($input:CreateProjectV2ViewInput!){createProjectV2View(input:$input){projectV2View{id}}}", { input: { projectId: detail.item.id, name: cleanName, layout: input.layout, configuration } });
    const viewID = text(object(object(response.createProjectV2View).projectV2View).id);
    if (!viewID) throw new Error(t("The server returned an unexpected response."));
    // CreateProjectV2ViewInput has no filter; its separate update can leave a created view on failure.
    if (input.filter) {
      try { await hubGraphql(c, "mutation($input:UpdateProjectV2ViewInput!){updateProjectV2View(input:$input){projectV2View{id}}}", { input: { viewId: viewID, filter: input.filter } }); }
      catch (error) { throw new HubUncertainWriteError(`${hubError(error, c.token)}\n\n${t("The server may have accepted the last change. Refresh and check the remote item before trying again.")}`); }
    }
  });
}

/** Validates the view still belongs to this project before a confirmed deletion. */
export async function deleteHubProjectView(c: HubAccess, detail: HubDetail, view: HubProjectView): Promise<void> {
  github(c, detail); await freshView(c, detail, view);
  await hubGraphql(c, "mutation($input:DeleteProjectV2ViewInput!){deleteProjectV2View(input:$input){projectV2View{id}}}", { input: { viewId: view.id } });
}
