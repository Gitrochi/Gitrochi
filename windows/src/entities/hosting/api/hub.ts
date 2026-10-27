import type { Provider, RepoTarget } from "@/entities/git";
import { t } from "@/shared/i18n";
import * as H from "./hosting";
import { localProjects, isLocalProject } from "../model/local-projects";

export type HostingHubSection = "releases" | "projects" | "organizations";
export interface HubAccess { target: RepoTarget; token: string; apiBase: string; me: string; stillCurrent?: () => boolean; local?: boolean }
export interface HubItem { id: string; title: string; subtitle: string; body: string; url: string; avatarURL?: string | null; editable?: boolean; data: Record<string, unknown> }
export interface HubPage { items: HubItem[]; more: boolean; cursor?: string; notice?: string }
export interface HubMember { id: string; name: string; username: string; role: string; avatarURL: string | null; url: string }
export interface HubRepository { id: string; name: string; description: string; cloneURL: string; url: string }
export type HubProjectFieldKind = "singleSelect" | "text" | "number" | "date" | "iteration" | "unsupported";
export interface HubProjectOption { id: string; name: string; startDate?: string; duration?: number }
export interface HubProjectField { id: string; name: string; options: HubProjectOption[]; kind?: HubProjectFieldKind }
export interface HubProjectRow { id: string; title: string; body: string; url: string; contentID: string; statuses: Record<string, string>; labels?: string[]; kind?: "issue" | "pullRequest" | "draft" | "redacted"; number?: number; repository?: string; state?: string; assignees?: string[]; updatedAt?: string; headRefName?: string; archived?: boolean; values?: Record<string, string>; author?: string; createdAt?: string }
export interface HubDetail { item: HubItem; members: HubMember[]; repositories: HubRepository[]; assets: { id: string; name: string; size?: number; downloads?: number; url: string }[]; fields: HubProjectField[]; rows: HubProjectRow[]; more: boolean; cursor?: string; notice?: string }
export interface HubReleaseInput { tag: string; name: string; body: string; target: string; draft: boolean; prerelease: boolean }
type J = Record<string, any>;
const pageSize = 30;
const enc = encodeURIComponent;
const repo = (c: HubAccess) => c.target.provider === "github" ? `${c.apiBase}/repos/${c.target.path.split("/").map(enc).join("/")}` : `${c.apiBase}/projects/${H.projectID(c.target.path)}`;
/** Local namespaces cannot reach a remote account, even through a stale confirmation. */
/** Credential-free context for the local planner. */
export function localHubAccess(stillCurrent?: () => boolean): HubAccess {
  return { local: true, target: { provider: "github", host: "local", path: "local/workspace", remote: "origin" }, token: "", apiBase: "", me: "", stillCurrent };
}

export function hubUsesLocal(c: HubAccess, item: HubItem): boolean {
  ensureHubCurrent(c);
  const local = isLocalProject(item) || item.id.startsWith("local:");
  if (!!c.local !== local) throw new Error(t("Switch to the matching project workspace before saving."));
  return local;
}
export function ensureHubCurrent(c: HubAccess) { if (c.stillCurrent?.() === false) throw new Error(t("The repository or account changed. Reopen this action.")); }
function assertAPI(c: HubAccess, url: string) { if(c.local)throw new Error(t("Local projects do not send requests to GitHub.")); const base = new URL(c.apiBase), u = new URL(url); if (u.origin !== base.origin || !u.pathname.startsWith(base.pathname.replace(/\/$/, "") + "/")) throw new Error(t("The server returned an unsafe address.")); }
async function request<T>(c: HubAccess, url: string, method = "GET", body?: unknown): Promise<T> { ensureHubCurrent(c); assertAPI(c, url); const value = await H.send<T>(c.target.provider, url, c.token, method, body); ensureHubCurrent(c); return value; }
async function raw(c: HubAccess, url: string, method: string, body?: unknown) { ensureHubCurrent(c); assertAPI(c, url); await H.sendRaw(c.target.provider, url, c.token, method, body); ensureHubCurrent(c); }
export function hubProjectTarget(repository: RepoTarget | null, provider: Provider, host: string, username: string, personal: boolean): RepoTarget {
  return !personal && repository ? repository : {provider,host,path:`${username}/workspace`,remote:"origin"};
}
export function hubProjectColumns(detail: HubDetail, fieldID?: string): { id: string; title: string; rows: HubProjectRow[] }[] {
  const groupFields = detail.fields.filter(value => value.options.length > 0);
  const field = groupFields.find(value => value.id === fieldID) ?? groupFields.find(value => /^(status|상태)$/i.test(value.name)) ?? groupFields[0];
  if (!field) return [{id:"",title:t("Not set"),rows:detail.rows}];
  const options = new Set(field.options.map(option => option.id));
  const unset = detail.rows.filter(row => !options.has((row.values?.[field.id] ?? row.statuses[field.id])));
  return [...(unset.length ? [{id:"",title:t("Not set"),rows:unset}] : []), ...field.options.map(option => ({id:option.id,title:option.name,rows:detail.rows.filter(row => (row.values?.[field.id] ?? row.statuses[field.id]) === option.id)}))];
}
export class HubProjectPermissionError extends Error {
  constructor() { super(t("Connect project access for this GitHub account to load projects.")); this.name = "HubProjectPermissionError"; }
}
export class HubProjectActionDeniedError extends Error {
  constructor(detail?: string) { super(`${t("GitHub denied this project action. Check the token's Projects access and the owner's policies. A paid plan does not grant these permissions.")}${detail ? `\n\n${detail}` : ""}`); this.name = "HubProjectActionDeniedError"; }
}
async function graphql<T>(c: HubAccess, query: string, variables: Record<string, unknown>): Promise<T> {
  const r = await request<{data?: T; errors?: {message: string; type?: string}[]}>(c, `${c.apiBase}/graphql`, "POST", {query, variables});
  if (r.errors?.some(error => error.type === "INSUFFICIENT_SCOPES" || /insufficient scope|required scopes|read:project/i.test(error.message))) throw new HubProjectPermissionError();
  if (r.errors?.some(error => error.type === "FORBIDDEN" || error.type === "RESOURCE_NOT_ACCESSIBLE")) throw new HubProjectActionDeniedError();
  if (r.errors?.length || !r.data) throw new Error(t("Projects could not be loaded. Retry or open GitHub in your browser."));
  return r.data;
}
export { graphql as hubGraphql, request as hubRequest };
export function hubSafeURL(c: {target: Pick<RepoTarget, "provider" | "host">}, value: string, asset = false): string | null { try { const u = new URL(value); if (u.protocol !== "https:" || u.username || u.password) return null; const allowed = new Set([c.target.host.toLowerCase(), ...(c.target.provider === "github" ? ["github.com", "gist.github.com", ...(asset ? ["objects.githubusercontent.com", "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"] : [])] : [])]); return allowed.has(u.hostname.toLowerCase()) ? u.href : null; } catch { return null; } }
export function hubError(error: unknown, token?: string): string { let s = error instanceof Error ? error.message : String(error); if (token) s = s.split(token).join("[redacted]"); return s.replace(/(https?:\/\/)[^\s/@]+:[^\s/@]+@/gi, "$1[redacted]@").replace(/\b(?:gh[pousr]_[\w]+|github_pat_[\w]+|glpat-[\w-]+)\b/g, "[redacted]").replace(/([?&](?:access_token|private_token|token|api_key)=)[^&\s]+/gi, "$1[redacted]").slice(0, 1200); }
export class HubUncertainWriteError extends Error { constructor(message: string, readonly createdProject?: HubItem) { super(message); } }
async function create(c:HubAccess,url:string,body:unknown){try{await raw(c,url,"POST",body);}catch(e){if(e instanceof H.HostingError&&e.status>=400&&e.status<500)throw e;throw new HubUncertainWriteError(`${hubError(e,c.token)}\n\n${t("The server may have accepted the last change. Refresh and check the remote item before trying again.")}`);}}
export function hubBoardIssueQuery(board: J, page: number): string {
  const q=new URLSearchParams({state:board.hide_closed_list?"opened":"all",scope:"all",per_page:"30",page:String(Math.max(1,page)),order_by:"updated_at"});
  const labels=(board.labels??[]).map((l:J)=>l.name).filter(Boolean);if(labels.length)q.set("labels",labels.join(","));
  if(board.assignee?.id!=null)q.set("assignee_id",String(board.assignee.id));
  if(board.milestone?.title)q.set("milestone",board.milestone.title);
  if(board.weight!=null)q.set("weight",String(board.weight));
  if(board.iteration?.id)q.set("iteration_id",String(board.iteration.id));
  return q.toString();
}
const empty = (item: HubItem): HubDetail => ({item, members: [], repositories: [], assets: [], fields: [], rows: [], more: false});
const memberRole = (level?: number): string => {
  switch (level) {
    case 5: return t("Minimal access");
    case 10: return t("Guest");
    case 15: return t("Planner");
    case 20: return t("Reporter");
    case 30: return t("Developer");
    case 40: return t("Maintainer");
    case 50: return t("Owner");
    default: return t("Member");
  }
};
function organizationAvatarURL(c: HubAccess, value: unknown): string | null {
  if (typeof value !== "string" || !value.trim()) return null;
  try {
    const avatar = value.startsWith("/") && !value.startsWith("//") ? new URL(value, c.apiBase) : new URL(value);
    const allowed = new Set([c.target.host.toLowerCase(), "gravatar.com", "www.gravatar.com", "secure.gravatar.com", ...(c.target.provider === "github" ? ["avatars.githubusercontent.com", "github.com"] : [])]);
    return avatar.protocol === "https:" && !avatar.username && !avatar.password && allowed.has(avatar.hostname.toLowerCase()) ? avatar.href : null;
  } catch { return null; }
}
function member(c: HubAccess, value: J): HubMember {
  const username = value.login ?? value.username ?? String(value.id);
  let avatarURL: string | null = null;
  try {
    const avatar = new URL(value.avatar_url);
    if (avatar.protocol === "https:" && !avatar.username && !avatar.password) avatarURL = avatar.href;
  } catch { /* The initials avatar remains available. */ }
  const fallback = `https://${c.target.host}/${enc(username)}`;
  return { id: String(value.id), name: value.name?.trim() || username, username, role: memberRole(value.access_level), avatarURL, url: hubSafeURL(c, value.html_url ?? value.web_url ?? fallback) ?? "" };
}
const releaseItem = (p: Provider, x: J): HubItem => ({id: String(p === "github" ? x.id : x.tag_name), title: x.name || x.tag_name, subtitle: `${x.tag_name}${x.draft ? " · draft" : ""}${x.prerelease ? " · prerelease" : ""}`, body: p === "github" ? x.body ?? "" : x.description ?? "", url: x.html_url ?? x._links?.self ?? "", data: x});
const projectFragment = "id number title shortDescription url closed updatedAt";
// macOS: HostingHubAPI.projectDetailQuery uses the same fields and bounded connections.
const projectDetailQuery = `query($id:ID!,$cursor:String){node(id:$id){... on ProjectV2{
  id title shortDescription readme url closed public updatedAt
  fields(first:100){nodes{
    ... on ProjectV2FieldCommon{id name dataType}
    ... on ProjectV2SingleSelectField{id name options{id name}}
    ... on ProjectV2IterationField{id name configuration{iterations{id title startDate duration} completedIterations{id title startDate duration}}}
  } pageInfo{hasNextPage}}
  items(first:30,after:$cursor,archivedStates:[ARCHIVED,NOT_ARCHIVED]){nodes{id type isArchived updatedAt content{__typename
    ... on Issue{id title body url number state createdAt author{login} updatedAt repository{nameWithOwner} assignees(first:100){nodes{login}} labels(first:100){nodes{name}}}
    ... on PullRequest{id title body url number state createdAt author{login} updatedAt headRefName repository{nameWithOwner} assignees(first:100){nodes{login}} labels(first:100){nodes{name}}}
    ... on DraftIssue{id title body createdAt creator{login} updatedAt assignees(first:100){nodes{login}}}
  } fieldValues(first:100){nodes{
    ... on ProjectV2ItemFieldSingleSelectValue{optionId field{... on ProjectV2SingleSelectField{id}}}
    ... on ProjectV2ItemFieldTextValue{text field{... on ProjectV2Field{id}}}
    ... on ProjectV2ItemFieldNumberValue{number field{... on ProjectV2Field{id}}}
    ... on ProjectV2ItemFieldDateValue{date field{... on ProjectV2Field{id}}}
    ... on ProjectV2ItemFieldIterationValue{iterationId field{... on ProjectV2IterationField{id}}}
  } pageInfo{hasNextPage}}} pageInfo{hasNextPage endCursor}}
}}}`;
function projectField(x: J): HubProjectField {
  if (Array.isArray(x.options)) return {id:x.id,name:x.name,options:x.options,kind:"singleSelect"};
  if (x.configuration) return {id:x.id,name:x.name,kind:"iteration",options:[...(x.configuration.iterations??[]),...(x.configuration.completedIterations??[])].map((option:J)=>({id:option.id,name:option.title,startDate:option.startDate,duration:option.duration}))};
  return {id:x.id,name:x.name,options:[],kind:({TEXT:"text",NUMBER:"number",DATE:"date"} as Record<string,HubProjectFieldKind>)[x.dataType]??"unsupported"};
}
function projectRow(x: J): HubProjectRow {
  const content=x.content??{}, values:Record<string,string>={},statuses:Record<string,string>={};
  for(const field of x.fieldValues?.nodes??[]){if(!field.field?.id)continue;const value=field.optionId??field.iterationId??field.text??field.number??field.date;if(value!=null)values[field.field.id]=String(value);if(field.optionId!=null)statuses[field.field.id]=field.optionId;}
  const kind=content.__typename==="PullRequest"?"pullRequest":content.__typename==="DraftIssue"?"draft":content.__typename==="Issue"?"issue":x.type==="DRAFT_ISSUE"?"draft":x.type==="PULL_REQUEST"?"pullRequest":content.id?"issue":"redacted";
  return {id:x.id,title:content.title??t("Redacted project item"),body:content.body??"",url:content.url??"",contentID:content.id??"",statuses,values,kind,number:content.number,repository:content.repository?.nameWithOwner??"",state:content.state??"",assignees:(content.assignees?.nodes??[]).map((a:J)=>a.login),labels:(content.labels?.nodes??[]).map((label:J)=>label.name),updatedAt:x.updatedAt??content.updatedAt??"",headRefName:content.headRefName??"",archived:!!x.isArchived,author:(kind==="draft"?content.creator?.login:content.author?.login)||undefined,createdAt:content.createdAt||undefined};
}
export async function hubPage(c: HubAccess, section: HostingHubSection, page = 1, cursor?: string): Promise<HubPage> {
  if(c.local){ensureHubCurrent(c);if(section!=="projects")throw new Error(t("This action requires a GitHub project."));await localProjects.load();ensureHubCurrent(c);if(localProjects.error)throw new Error(localProjects.error);return{items:localProjects.projects,more:false,notice:t("Saved on this device. Local projects do not sync with GitHub.")};}
  const query = `per_page=${pageSize}&page=${Math.max(1, page)}`;
  if (section === "releases") { const list = await request<J[]>(c, `${repo(c)}/releases?${query}`); return {items: list.map(x => releaseItem(c.target.provider, x)), more: list.length === pageSize, notice: c.target.provider === "gitlab" ? t("GitLab releases are published immediately; GitHub-style drafts and prereleases are unavailable.") : undefined}; }
  if (section === "organizations") { const list = await request<J[]>(c, `${c.apiBase}/${c.target.provider === "github" ? "user/orgs" : "groups?all_available=false"}${c.target.provider === "github" ? "?" : "&"}${query}`); return {items: list.map(x => ({id: String(c.target.provider === "github" ? x.login : x.id), title: x.name || x.login || x.full_name, subtitle: x.full_path ?? x.login, body: x.description ?? "", url: x.html_url ?? x.web_url ?? `https://github.com/${enc(x.login)}`, avatarURL: organizationAvatarURL(c, x.avatar_url), data: x})), more: list.length === pageSize}; }
  if (c.target.provider === "gitlab") { if (c.target.path.endsWith("/workspace")) throw new Error(t("Open a GitLab repository to browse its issue boards.")); const list = await request<J[]>(c, `${repo(c)}/boards`); return {items: list.slice((page-1)*pageSize,page*pageSize).map(x => ({id: String(x.id), title: x.name, subtitle: t("GitLab issue board"), body: "", url: `https://${c.target.host}/${c.target.path}/-/boards/${x.id}`, data: x})), more: list.length > page*pageSize}; }
  const [owner, name] = c.target.path.split("/");
  const noRepo = name === "workspace";
  const r = await graphql<{user?: {projectsV2: J}; repository?: {owner: {projectsV2: J}}}>(c, noRepo ? `query($owner:String!,$cursor:String){user(login:$owner){projectsV2(first:30,after:$cursor){nodes{${projectFragment}} pageInfo{hasNextPage endCursor}}}}` : `query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){owner{... on User{projectsV2(first:30,after:$cursor){nodes{${projectFragment}} pageInfo{hasNextPage endCursor}}} ... on Organization{projectsV2(first:30,after:$cursor){nodes{${projectFragment}} pageInfo{hasNextPage endCursor}}}}}}`, noRepo ? {owner, cursor: cursor ?? null} : {owner, name, cursor: cursor ?? null});
  const p = noRepo ? r.user?.projectsV2 : r.repository?.owner?.projectsV2; if (!p) throw new Error(t("Projects are unavailable for this repository owner."));
  return {items: p.nodes.map((x: J) => ({id: x.id, title: x.title, subtitle: `#${x.number}${x.closed ? " · closed" : ""}`, body: x.shortDescription ?? "", url: x.url, data: x})), more: p.pageInfo.hasNextPage, cursor: p.pageInfo.endCursor, notice: t("Projects sync with GitHub. Changes are saved after confirmation.")};
}
export async function hubDetail(c: HubAccess, section: HostingHubSection, item: HubItem, page = 1, cursor?: string, tab: "repositories" | "members" = "repositories"): Promise<HubDetail> {
  if(hubUsesLocal(c,item)){if(section!=="projects")throw new Error(t("This action requires a GitHub project."));const result=await localProjects.detail(item.id);ensureHubCurrent(c);return result;}
  const p = c.target.provider, qs = `per_page=${pageSize}&page=${page}`;
  if (section === "releases") { const x = await request<J>(c, `${repo(c)}/releases/${enc(item.id)}`); const d = empty(releaseItem(p,x)); d.assets = p === "github" ? (x.assets ?? []).map((a: J) => ({id:String(a.id),name:a.name,size:a.size,downloads:a.download_count,url:a.browser_download_url})) : [...(x.assets?.links ?? []).map((a: J) => ({id:String(a.id),name:a.name,url:a.direct_asset_url ?? a.url})), ...(x.assets?.sources ?? []).map((a: J) => ({id:a.format,name:a.format,url:a.url}))]; return d; }
  if (section === "organizations") { const base = `${c.apiBase}/${p === "github" ? "orgs" : "groups"}/${enc(item.id)}`; const x = await request<J>(c, base); const d = empty({...item,title:x.name || item.title,body:x.description ?? "",url:x.html_url ?? x.web_url ?? item.url,avatarURL:x.avatar_url === undefined ? item.avatarURL : organizationAvatarURL(c, x.avatar_url),data:x}); const list = await request<J[]>(c, `${base}/${tab === "members" ? p === "github" ? "members" : "members/all" : p === "github" ? "repos" : "projects"}?${qs}${tab === "repositories" ? p === "github" ? "&sort=updated" : "&include_subgroups=true&order_by=last_activity_at" : ""}`); if (tab === "members") d.members = list.map(a => member(c, a)); else d.repositories = list.map(a => ({id:String(a.id),name:a.full_name ?? a.path_with_namespace,description:a.description ?? "",cloneURL:a.clone_url ?? a.http_url_to_repo,url:a.html_url ?? a.web_url})); d.more = list.length === pageSize; d.notice = p === "github" && tab === "members" ? t("Only members visible to this account are returned by the server.") : undefined; return d; }
  if (p === "gitlab") { const board = await request<J>(c, `${repo(c)}/boards/${enc(item.id)}`); const lists = await request<J[]>(c, `${repo(c)}/boards/${enc(item.id)}/lists?per_page=100`); const labels = lists.filter(x=>x.label).map(x=>({id:String(x.label.id),name:x.label.name})); const issues = await request<J[]>(c, `${repo(c)}/issues?${hubBoardIssueQuery(board,page)}`); const d=empty({...item,title:board.name,data:board}); d.fields=[{id:"board",name:t("Board column"),options:[{id:"__open",name:t("Open")},...labels,{id:"__closed",name:t("Closed")}]}]; d.rows=issues.map(x=>({id:String(x.iid),title:x.title,body:x.description??"",url:x.web_url,contentID:String(x.id),kind:"issue",number:x.iid,repository:c.target.path,state:x.state==="closed"?"CLOSED":"OPEN",assignees:(x.assignees??[]).map((a:J)=>a.username),updatedAt:x.updated_at??"",author:x.author?.username||undefined,createdAt:x.created_at||undefined,labels:x.labels??[],statuses:{board:x.state==="closed"?"__closed":labels.find(l=>(x.labels??[]).includes(l.name))?.id??"__open"}})); d.more=issues.length===pageSize; d.notice=t("GitLab board scope filters are applied. Only label columns can be moved here; assignee, milestone, iteration and custom status columns remain available in the browser. Moving to Open reopens the issue and removes its board column labels."); return d; }
  const r = await graphql<{node:J}>(c, projectDetailQuery, {id:item.id,cursor:cursor??null});
  const x=r.node;if(!x?.id) throw new Error(t("Project is unavailable or this account cannot access it."));
  const d=empty({...item,title:x.title,body:x.shortDescription??"",url:x.url,data:{...item.data,...x}});
  d.fields=(x.fields?.nodes??[]).filter((field:J)=>field.id).map(projectField);
  d.rows=(x.items?.nodes??[]).map(projectRow);d.more=!!x.items?.pageInfo?.hasNextPage;d.cursor=x.items?.pageInfo?.endCursor;
  if(x.fields?.pageInfo?.hasNextPage||x.items?.nodes?.some((row:J)=>row.fieldValues?.pageInfo?.hasNextPage))d.notice=t("Some project fields were truncated by the server. Only loaded fields can be edited.");
  return d;
}
export async function saveHubRelease(c: HubAccess, input: HubReleaseInput, previous?: HubItem) {
  if (!input.tag.trim() || !input.name.trim()) throw new Error(t("A tag and release name are required."));
  if (c.target.provider === "gitlab" && (input.draft || input.prerelease)) throw new Error(t("GitLab releases are published immediately; GitHub-style drafts and prereleases are unavailable."));
  if (previous) { if(input.tag.trim()!==previous.data.tag_name)throw new Error(t("The existing release tag cannot be changed here.")); const fresh = await hubDetail(c,"releases",previous); if (fresh.item.data.updated_at !== previous.data.updated_at || fresh.item.body!==previous.body || fresh.item.title!==previous.title) throw new Error(t("This item changed on the server. Refresh before saving.")); }
  const body = c.target.provider === "github" ? {tag_name:input.tag.trim(),name:input.name.trim(),body:input.body,target_commitish:input.target.trim()||undefined,draft:input.draft,prerelease:input.prerelease} : {tag_name:input.tag.trim(),name:input.name.trim(),description:input.body,...(!previous&&input.target.trim()?{ref:input.target.trim()}:{})};
  if(previous)await raw(c,`${repo(c)}/releases/${enc(previous.id)}`,c.target.provider==="github"?"PATCH":"PUT",body);else await create(c,`${repo(c)}/releases`,body);
}
export async function deleteHubItem(c: HubAccess, item: HubItem) { const fresh=await hubDetail(c,"releases",item); if(fresh.item.data.updated_at!==item.data.updated_at||fresh.item.title!==item.title||fresh.item.body!==item.body)throw new Error(t("This item changed on the server. Refresh before saving.")); await raw(c,`${repo(c)}/releases/${enc(item.id)}`,"DELETE"); }
/** Writes only fields and items present in the captured project detail. */
function loadedProjectRow(detail:HubDetail,row:HubProjectRow) {
  const loaded=detail.rows.find(value=>value.id===row.id);
  if(!detail.item.id||!loaded)throw new Error(t("Select a loaded project field and item."));
  return loaded;
}
function githubProject(c:HubAccess,detail:HubDetail){ensureHubCurrent(c);if(hubUsesLocal(c,detail.item)||c.target.provider!=="github"||!detail.item.id)throw new Error(t("This action requires a GitHub project."));}
export async function updateHubProjectField(c:HubAccess,detail:HubDetail,row:HubProjectRow,field:HubProjectField,value:string|null|undefined) {
  if(hubUsesLocal(c,detail.item)){await localProjects.updateField(detail,row,field,value);ensureHubCurrent(c);return;}
  githubProject(c,detail);const loaded=loadedProjectRow(detail,row),actual=detail.fields.find(candidate=>candidate.id===field.id);
  if(!actual)throw new Error(t("Select a loaded project field and item."));
  const kind=actual.kind??(actual.options.length?"singleSelect":"unsupported");
  if(kind==="unsupported")throw new Error(t("This project field is managed by its issue or pull request."));
  const input:J={projectId:detail.item.id,itemId:loaded.id,fieldId:actual.id};
  if(value==null){await graphql(c,"mutation($input:ClearProjectV2ItemFieldValueInput!){clearProjectV2ItemFieldValue(input:$input){projectV2Item{id}}}",{input});return;}
  let fieldValue:Record<string,string|number>;
  if(kind==="singleSelect"||kind==="iteration"){
    if(!actual.options.some(option=>option.id===value))throw new Error(t("Select a loaded project field and item."));
    fieldValue={[kind==="iteration"?"iterationId":"singleSelectOptionId"]:value};
  }else if(kind==="number"){
    if(!/^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/.test(value.trim())||!Number.isFinite(Number(value)))throw new Error(t("Enter a valid number."));fieldValue={number:Number(value)};
  }else if(kind==="date"){
    if(!/^\d{4}-\d{2}-\d{2}$/.test(value)||!Number.isFinite(Date.parse(value))||new Date(value).toISOString().slice(0,10)!==value)throw new Error(t("Enter a date as YYYY-MM-DD."));fieldValue={date:value};
  }else fieldValue={text:value};
  await graphql(c,"mutation($input:UpdateProjectV2ItemFieldValueInput!){updateProjectV2ItemFieldValue(input:$input){projectV2Item{id}}}",{input:{...input,value:fieldValue}});
}
export async function saveHubProjectDraft(c:HubAccess,detail:HubDetail,title:string,body:string,row?:HubProjectRow) {
  if(hubUsesLocal(c,detail.item)){await localProjects.saveDraft(detail,title,body,row);ensureHubCurrent(c);return;}
  githubProject(c,detail);if(!title.trim())throw new Error(t("A draft title is required."));
  if(row){
    const loaded=loadedProjectRow(detail,row);if(loaded.kind!=="draft"||!loaded.contentID)throw new Error(t("Select a loaded draft item."));
    const fresh=await graphql<{node:J}>(c,"query($id:ID!){node(id:$id){... on DraftIssue{id title body}}}",{id:loaded.contentID});
    if(fresh.node?.id!==loaded.contentID||(fresh.node.title??"")!==loaded.title||(fresh.node.body??"")!==loaded.body)throw new Error(t("This item changed on the server. Refresh before saving."));
    await graphql(c,"mutation($input:UpdateProjectV2DraftIssueInput!){updateProjectV2DraftIssue(input:$input){draftIssue{id}}}",{input:{draftIssueId:loaded.contentID,title:title.trim(),body}});
  }
  else {try{await graphql(c,"mutation($input:AddProjectV2DraftIssueInput!){addProjectV2DraftIssue(input:$input){projectItem{id}}}",{input:{projectId:detail.item.id,title:title.trim(),body}});}catch(error){if(error instanceof H.HostingError&&error.status>=400&&error.status<500||error instanceof HubProjectPermissionError||error instanceof HubProjectActionDeniedError)throw error;throw new HubUncertainWriteError(`${hubError(error,c.token)}\n\n${t("The server may have accepted the last change. Refresh and check the remote item before trying again.")}`);}}
}
export async function archiveHubProjectItem(c:HubAccess,detail:HubDetail,row:HubProjectRow,archived:boolean) {
  if(hubUsesLocal(c,detail.item)){await localProjects.archive(detail,row,archived);ensureHubCurrent(c);return;}
  githubProject(c,detail);const loaded=loadedProjectRow(detail,row),operation=archived?"archiveProjectV2Item":"unarchiveProjectV2Item",inputType=archived?"ArchiveProjectV2ItemInput":"UnarchiveProjectV2ItemInput";
  await graphql(c,`mutation($input:${inputType}!){${operation}(input:$input){item{id}}}`,{input:{projectId:detail.item.id,itemId:loaded.id}});
}
export async function deleteHubProjectItem(c:HubAccess,detail:HubDetail,row:HubProjectRow) {
  if(hubUsesLocal(c,detail.item)){await localProjects.removeItem(detail,row);ensureHubCurrent(c);return;}
  githubProject(c,detail);const loaded=loadedProjectRow(detail,row);
  await graphql(c,"mutation($input:DeleteProjectV2ItemInput!){deleteProjectV2Item(input:$input){deletedItemId}}",{input:{projectId:detail.item.id,itemId:loaded.id}});
}
/** Reorders a loaded project item; a null anchor moves it to the top. */
export async function moveHubProjectItemPosition(c:HubAccess,detail:HubDetail,row:HubProjectRow,afterRow:HubProjectRow|null) {
  if(hubUsesLocal(c,detail.item)){await localProjects.reorder(detail,row,afterRow);ensureHubCurrent(c);return;}
  githubProject(c,detail);const loaded=loadedProjectRow(detail,row),anchor=afterRow?loadedProjectRow(detail,afterRow):null;
  if(anchor?.id===loaded.id)throw new Error(t("Select a loaded project field and item."));
  await graphql(c,"mutation($input:UpdateProjectV2ItemPositionInput!){updateProjectV2ItemPosition(input:$input){items{nodes{id}}}}",{input:{projectId:detail.item.id,itemId:loaded.id,afterId:anchor?.id??null}});
}
/** Converts a loaded draft into an issue in a repository on the captured account's server. */
export async function convertHubProjectDraftToIssue(c:HubAccess,detail:HubDetail,row:HubProjectRow,repository:string) {
  githubProject(c,detail);const loaded=loadedProjectRow(detail,row);
  if(loaded.kind!=="draft"||!loaded.contentID)throw new Error(t("Select a loaded draft item."));
  const path=repository.trim(),parts=path.split("/");
  if(parts.length!==2||parts.some(part=>!part||part==="."||part===".."||!/^[A-Za-z0-9_.-]+$/.test(part)))throw new Error(t("Enter a repository as owner/name on the connected server."));
  const data=await graphql<{repository:J|null}>(c,"query($owner:String!,$name:String!){repository(owner:$owner,name:$name){id nameWithOwner}}",{owner:parts[0],name:parts[1]});
  if(!data.repository?.id||String(data.repository.nameWithOwner).toLowerCase()!==path.toLowerCase())throw new Error(t("Repository is unavailable or this account cannot access it."));
  try{await graphql(c,"mutation($input:ConvertProjectV2DraftIssueItemToIssueInput!){convertProjectV2DraftIssueItemToIssue(input:$input){item{id}}}",{input:{itemId:loaded.id,repositoryId:data.repository.id}});}
  catch(error){if(error instanceof H.HostingError&&error.status>=400&&error.status<500||error instanceof HubProjectPermissionError||error instanceof HubProjectActionDeniedError)throw error;throw new HubUncertainWriteError(`${hubError(error,c.token)}\n\n${t("The server may have accepted the last change. Refresh and check the remote item before trying again.")}`);}
}
export async function moveHubProjectItem(c:HubAccess,detail:HubDetail,row:HubProjectRow,field:HubProjectField,option:string){
  if(c.target.provider==="github"){await updateHubProjectField(c,detail,row,field,option);return;}
  const loaded=loadedProjectRow(detail,row),actual=detail.fields.find(value=>value.id===field.id);
  if(!actual?.options.some(value=>value.id===option))throw new Error(t("Select a loaded project field and item."));
  const fresh=await request<J>(c,`${repo(c)}/issues/${enc(loaded.id)}`),boardLabels=actual.options.filter(value=>!value.id.startsWith("__")).map(value=>value.name),label=actual.options.find(value=>value.id===option&&!value.id.startsWith("__"))?.name;
  await raw(c,`${repo(c)}/issues/${enc(loaded.id)}`,"PUT",{remove_labels:(fresh.labels??[]).filter((value:string)=>boardLabels.includes(value)&&value!==label).join(","),...(label?{add_labels:label}:{}),state_event:option==="__closed"?"close":"reopen"});
}
export async function addHubProjectIssue(c:HubAccess,detail:HubDetail,issueURL:string,option?:string){
  const u=hubSafeURL(c,issueURL);if(!u||new URL(u).hostname.toLowerCase()!==c.target.host.toLowerCase())throw new Error(t("Enter an issue URL from the connected server."));
  const parsed=new URL(u),match=parsed.pathname.match(c.target.provider==="github"?/^\/([^/]+)\/([^/]+)\/(issues|pull)\/([1-9]\d*)\/?$/:/^\/(.+)\/-\/issues\/([1-9]\d*)\/?$/);
  if(!match)throw new Error(t("Enter a full issue or pull request URL."));
  if(c.target.provider==="github"){
    githubProject(c,detail);const isPR=match[3]==="pull",issue=await request<J>(c,`${c.apiBase}/repos/${enc(match[1])}/${enc(match[2])}/${isPR?"pulls":"issues"}/${match[4]}`);
    if(!issue.node_id||(!isPR&&issue.pull_request))throw new Error(t("Select an issue or pull request from this server."));
    await graphql(c,"mutation($input:AddProjectV2ItemByIdInput!){addProjectV2ItemById(input:$input){item{id}}}",{input:{projectId:detail.item.id,contentId:issue.node_id}});
  }else{
    if(decodeURIComponent(match[1])!==c.target.path)throw new Error(t("Select an issue from this board's repository."));const field=detail.fields[0];if(!field)throw new Error(t("Refresh the board before adding an issue."));
    const x=await request<J>(c,`${repo(c)}/issues/${match[2]}`),row:HubProjectRow={id:String(x.iid),title:x.title,body:"",url:u,contentID:String(x.id),statuses:{},labels:x.labels??[]};await moveHubProjectItem(c,{...detail,rows:[...detail.rows,row]},row,field,option??"__open");
  }
}
