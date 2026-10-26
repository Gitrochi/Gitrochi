import type { Provider, RepoTarget } from "@/entities/git";
import { t } from "@/shared/i18n";
import * as H from "./hosting";

export type HostingHubSection = "releases" | "projects" | "organizations" | "gists";
export interface HubAccess { target: RepoTarget; token: string; apiBase: string; me: string; stillCurrent?: () => boolean }
export interface HubItem { id: string; title: string; subtitle: string; body: string; url: string; avatarURL?: string | null; editable?: boolean; data: Record<string, unknown> }
export interface HubPage { items: HubItem[]; more: boolean; cursor?: string; notice?: string }
export interface HubFile { name: string; content: string; truncated: boolean }
export interface HubMember { id: string; name: string; username: string; role: string; avatarURL: string | null; url: string }
export interface HubRepository { id: string; name: string; description: string; cloneURL: string; url: string }
export interface HubProjectField { id: string; name: string; options: { id: string; name: string }[] }
export interface HubProjectRow { id: string; title: string; body: string; url: string; contentID: string; statuses: Record<string, string>; labels?: string[] }
export interface HubDetail { item: HubItem; files: HubFile[]; members: HubMember[]; repositories: HubRepository[]; assets: { id: string; name: string; size?: number; downloads?: number; url: string }[]; fields: HubProjectField[]; rows: HubProjectRow[]; more: boolean; cursor?: string; notice?: string; starred?: boolean }
export interface HubReleaseInput { tag: string; name: string; body: string; target: string; draft: boolean; prerelease: boolean }
export interface HubGistInput { description: string; public: boolean; files: { name: string; content: string }[] }
type J = Record<string, any>;
const pageSize = 30;
const enc = encodeURIComponent;
const repo = (c: HubAccess) => c.target.provider === "github" ? `${c.apiBase}/repos/${c.target.path.split("/").map(enc).join("/")}` : `${c.apiBase}/projects/${H.projectID(c.target.path)}`;
export function ensureHubCurrent(c: HubAccess) { if (c.stillCurrent?.() === false) throw new Error(t("The repository or account changed. Reopen this action.")); }
function assertAPI(c: HubAccess, url: string) { const base = new URL(c.apiBase), u = new URL(url); if (u.origin !== base.origin || !u.pathname.startsWith(base.pathname.replace(/\/$/, "") + "/")) throw new Error(t("The server returned an unsafe address.")); }
async function request<T>(c: HubAccess, url: string, method = "GET", body?: unknown): Promise<T> { ensureHubCurrent(c); assertAPI(c, url); const value = await H.send<T>(c.target.provider, url, c.token, method, body); ensureHubCurrent(c); return value; }
async function raw(c: HubAccess, url: string, method: string, body?: unknown) { ensureHubCurrent(c); assertAPI(c, url); await H.sendRaw(c.target.provider, url, c.token, method, body); ensureHubCurrent(c); }
export function hubProjectTarget(repository: RepoTarget | null, provider: Provider, host: string, username: string, personal: boolean): RepoTarget {
  return !personal && repository ? repository : {provider,host,path:`${username}/workspace`,remote:"origin"};
}
export function hubProjectColumns(detail: HubDetail, fieldID?: string): { id: string; title: string; rows: HubProjectRow[] }[] {
  const field = detail.fields.find(value => value.id === fieldID) ?? detail.fields.find(value => /^(status|상태)$/i.test(value.name)) ?? detail.fields[0];
  if (!field) return [{id:"",title:t("Not set"),rows:detail.rows}];
  const options = new Set(field.options.map(option => option.id));
  const unset = detail.rows.filter(row => !options.has(row.statuses[field.id]));
  return [...(unset.length ? [{id:"",title:t("Not set"),rows:unset}] : []), ...field.options.map(option => ({id:option.id,title:option.name,rows:detail.rows.filter(row => row.statuses[field.id] === option.id)}))];
}
export class HubProjectPermissionError extends Error {
  constructor() { super(t("Connect project access for this GitHub account to load projects.")); this.name = "HubProjectPermissionError"; }
}
async function graphql<T>(c: HubAccess, query: string, variables: Record<string, unknown>): Promise<T> {
  const r = await request<{data?: T; errors?: {message: string; type?: string}[]}>(c, `${c.apiBase}/graphql`, "POST", {query, variables});
  if (r.errors?.some(error => error.type === "INSUFFICIENT_SCOPES" || /insufficient scope|required scopes|read:project/i.test(error.message))) throw new HubProjectPermissionError();
  if (r.errors?.length || !r.data) throw new Error(t("Projects could not be loaded. Retry or open GitHub in your browser."));
  return r.data;
}
export function hubSafeURL(c: {target: Pick<RepoTarget, "provider" | "host">}, value: string, asset = false): string | null { try { const u = new URL(value); if (u.protocol !== "https:" || u.username || u.password) return null; const allowed = new Set([c.target.host.toLowerCase(), ...(c.target.provider === "github" ? ["github.com", "gist.github.com", ...(asset ? ["objects.githubusercontent.com", "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"] : [])] : [])]); return allowed.has(u.hostname.toLowerCase()) ? u.href : null; } catch { return null; } }
export function hubError(error: unknown, token?: string): string { let s = error instanceof Error ? error.message : String(error); if (token) s = s.split(token).join("[redacted]"); return s.replace(/(https?:\/\/)[^\s/@]+:[^\s/@]+@/gi, "$1[redacted]@").replace(/\b(?:gh[pousr]_[\w]+|github_pat_[\w]+|glpat-[\w-]+)\b/g, "[redacted]").replace(/([?&](?:access_token|private_token|token|api_key)=)[^&\s]+/gi, "$1[redacted]").slice(0, 1200); }
export class HubUncertainWriteError extends Error {}
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
const empty = (item: HubItem): HubDetail => ({item, files: [], members: [], repositories: [], assets: [], fields: [], rows: [], more: false});
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
const gistItem = (p: Provider, x: J, me: string): HubItem => ({id: String(x.id), title: x.description || x.title || Object.keys(x.files ?? {})[0] || String(x.id), subtitle: `${p === "github" ? x.public ? "public" : "secret" : x.visibility} · ${x.owner?.login ?? x.author?.username ?? ""}`, body: x.description ?? "", url: x.html_url ?? x.web_url ?? "", editable: (x.owner?.login ?? x.author?.username) === me, data: x});
const projectFragment = "id number title shortDescription url closed";
export async function hubPage(c: HubAccess, section: HostingHubSection, page = 1, cursor?: string): Promise<HubPage> {
  const query = `per_page=${pageSize}&page=${Math.max(1, page)}`;
  if (section === "releases") { const list = await request<J[]>(c, `${repo(c)}/releases?${query}`); return {items: list.map(x => releaseItem(c.target.provider, x)), more: list.length === pageSize, notice: c.target.provider === "gitlab" ? t("GitLab releases are published immediately; GitHub-style drafts and prereleases are unavailable.") : undefined}; }
  if (section === "organizations") { const list = await request<J[]>(c, `${c.apiBase}/${c.target.provider === "github" ? "user/orgs" : "groups?all_available=false"}${c.target.provider === "github" ? "?" : "&"}${query}`); return {items: list.map(x => ({id: String(c.target.provider === "github" ? x.login : x.id), title: x.name || x.login || x.full_name, subtitle: x.full_path ?? x.login, body: x.description ?? "", url: x.html_url ?? x.web_url ?? `https://github.com/${enc(x.login)}`, avatarURL: organizationAvatarURL(c, x.avatar_url), data: x})), more: list.length === pageSize}; }
  if (section === "gists") { const list = await request<J[]>(c, `${c.apiBase}/${c.target.provider === "github" ? "gists" : "snippets"}?${query}`); return {items: list.map(x => gistItem(c.target.provider, x, c.me)), more: list.length === pageSize, notice: c.target.provider === "gitlab" ? t("GitLab personal snippets correspond to gists. Stars are not supported by its snippets API.") : undefined}; }
  if (c.target.provider === "gitlab") { if (c.target.path.endsWith("/workspace")) throw new Error(t("Open a GitLab repository to browse its issue boards.")); const list = await request<J[]>(c, `${repo(c)}/boards`); return {items: list.slice((page-1)*pageSize,page*pageSize).map(x => ({id: String(x.id), title: x.name, subtitle: t("GitLab issue board"), body: "", url: `https://${c.target.host}/${c.target.path}/-/boards/${x.id}`, data: x})), more: list.length > page*pageSize}; }
  const [owner, name] = c.target.path.split("/");
  const noRepo = name === "workspace";
  const r = await graphql<{user?: {projectsV2: J}; repository?: {owner: {projectsV2: J}}}>(c, noRepo ? `query($owner:String!,$cursor:String){user(login:$owner){projectsV2(first:30,after:$cursor){nodes{${projectFragment}} pageInfo{hasNextPage endCursor}}}}` : `query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){owner{... on User{projectsV2(first:30,after:$cursor){nodes{${projectFragment}} pageInfo{hasNextPage endCursor}}} ... on Organization{projectsV2(first:30,after:$cursor){nodes{${projectFragment}} pageInfo{hasNextPage endCursor}}}}}}`, noRepo ? {owner, cursor: cursor ?? null} : {owner, name, cursor: cursor ?? null});
  const p = noRepo ? r.user?.projectsV2 : r.repository?.owner?.projectsV2; if (!p) throw new Error(t("Projects are unavailable for this repository owner."));
  return {items: p.nodes.map((x: J) => ({id: x.id, title: x.title, subtitle: `#${x.number}${x.closed ? " · closed" : ""}`, body: x.shortDescription ?? "", url: x.url, data: x})), more: p.pageInfo.hasNextPage, cursor: p.pageInfo.endCursor, notice: t("Projects sync with GitHub. Changes are saved after confirmation.")};
}
export function hubSnippetRef(rawURL: string, file: string): string { try { const path=decodeURIComponent(new URL(rawURL).pathname),start=path.indexOf("/raw/"); if(start>=0&&path.endsWith("/"+file)){const ref=path.slice(start+5,-file.length-1); if(ref)return ref;} } catch {} return "main"; }
export async function hubDetail(c: HubAccess, section: HostingHubSection, item: HubItem, page = 1, cursor?: string, tab: "repositories" | "members" = "repositories"): Promise<HubDetail> {
  const p = c.target.provider, qs = `per_page=${pageSize}&page=${page}`;
  if (section === "releases") { const x = await request<J>(c, `${repo(c)}/releases/${enc(item.id)}`); const d = empty(releaseItem(p,x)); d.assets = p === "github" ? (x.assets ?? []).map((a: J) => ({id:String(a.id),name:a.name,size:a.size,downloads:a.download_count,url:a.browser_download_url})) : [...(x.assets?.links ?? []).map((a: J) => ({id:String(a.id),name:a.name,url:a.direct_asset_url ?? a.url})), ...(x.assets?.sources ?? []).map((a: J) => ({id:a.format,name:a.format,url:a.url}))]; return d; }
  if (section === "organizations") { const base = `${c.apiBase}/${p === "github" ? "orgs" : "groups"}/${enc(item.id)}`; const x = await request<J>(c, base); const d = empty({...item,title:x.name || item.title,body:x.description ?? "",url:x.html_url ?? x.web_url ?? item.url,avatarURL:x.avatar_url === undefined ? item.avatarURL : organizationAvatarURL(c, x.avatar_url),data:x}); const list = await request<J[]>(c, `${base}/${tab === "members" ? p === "github" ? "members" : "members/all" : p === "github" ? "repos" : "projects"}?${qs}${tab === "repositories" ? p === "github" ? "&sort=updated" : "&include_subgroups=true&order_by=last_activity_at" : ""}`); if (tab === "members") d.members = list.map(a => member(c, a)); else d.repositories = list.map(a => ({id:String(a.id),name:a.full_name ?? a.path_with_namespace,description:a.description ?? "",cloneURL:a.clone_url ?? a.http_url_to_repo,url:a.html_url ?? a.web_url})); d.more = list.length === pageSize; d.notice = p === "github" && tab === "members" ? t("Only members visible to this account are returned by the server.") : undefined; return d; }
  if (section === "gists") { const base = `${c.apiBase}/${p === "github" ? "gists" : "snippets"}/${enc(item.id)}`; const x = await request<J>(c, base); const d = empty(gistItem(p,x,c.me)); if (p === "github") { d.files = Object.entries(x.files ?? {}).map(([name,v]) => { const a=v as J; return {name,content:a.content ?? "",truncated:!!a.truncated}; }); try { await raw(c,base+"/star","GET"); d.starred = true; } catch(e) { if (e instanceof H.HostingError && e.status === 404) d.starred=false; else d.notice = t("Star status could not be loaded: {0}",hubError(e,c.token)); } if (x.truncated) d.notice = t("The server truncated the file list. Open the gist in a browser before editing."); } else { const files = x.files ?? [{path:x.file_name}]; for (const f of files.slice(0,30)) { const content = await (async () => { ensureHubCurrent(c); const value = await H.sendRaw(p, `${base}/files/${enc(x.default_branch ?? hubSnippetRef(f.raw_url ?? "",f.path ?? f.file_name))}/${enc(f.path ?? f.file_name)}/raw`, c.token); ensureHubCurrent(c); return value; })(); d.files.push({name:f.path ?? f.file_name,content:content.slice(0,1_000_000),truncated:content.length>1_000_000}); } if(files.length>30) d.notice=t("The server returned more files. Open the snippet in a browser before editing."); } return d; }
  if (p === "gitlab") { const board = await request<J>(c, `${repo(c)}/boards/${enc(item.id)}`); const lists = await request<J[]>(c, `${repo(c)}/boards/${enc(item.id)}/lists?per_page=100`); const labels = lists.filter(x=>x.label).map(x=>({id:String(x.label.id),name:x.label.name})); const issues = await request<J[]>(c, `${repo(c)}/issues?${hubBoardIssueQuery(board,page)}`); const d=empty({...item,title:board.name,data:board}); d.fields=[{id:"board",name:t("Board column"),options:[{id:"__open",name:t("Open")},...labels,{id:"__closed",name:t("Closed")}]}]; d.rows=issues.map(x=>({id:String(x.iid),title:x.title,body:x.description??"",url:x.web_url,contentID:String(x.id),labels:x.labels??[],statuses:{board:x.state==="closed"?"__closed":labels.find(l=>(x.labels??[]).includes(l.name))?.id??"__open"}})); d.more=issues.length===pageSize; d.notice=t("GitLab board scope filters are applied. Only label columns can be moved here; assignee, milestone, iteration and custom status columns remain available in the browser. Moving to Open reopens the issue and removes its board column labels."); return d; }
  const r = await graphql<{node:J}>(c, `query($id:ID!,$cursor:String){node(id:$id){... on ProjectV2{id title shortDescription url fields(first:100){nodes{... on ProjectV2Field{id name} ... on ProjectV2SingleSelectField{id name options{id name}}} pageInfo{hasNextPage}} items(first:30,after:$cursor){nodes{id content{... on Issue{id title body url} ... on PullRequest{id title body url} ... on DraftIssue{id title body}} fieldValues(first:100){nodes{... on ProjectV2ItemFieldSingleSelectValue{optionId field{... on ProjectV2SingleSelectField{id}}}} pageInfo{hasNextPage}}} pageInfo{hasNextPage endCursor}}}}}`, {id:item.id,cursor:cursor??null}); const x=r.node;if(!x?.id) throw new Error(t("Project is unavailable or this account cannot access it.")); const d=empty({...item,title:x.title,body:x.shortDescription??"",url:x.url}); d.fields=(x.fields.nodes??[]).filter((f:J)=>f.options?.length).map((f:J)=>({id:f.id,name:f.name,options:f.options}));d.rows=(x.items.nodes??[]).map((v:J)=>({id:v.id,title:v.content?.title??t("Redacted project item"),body:v.content?.body??"",url:v.content?.url??"",contentID:v.content?.id??"",statuses:Object.fromEntries((v.fieldValues.nodes??[]).filter((f:J)=>f.field?.id).map((f:J)=>[f.field.id,f.optionId]))}));d.more=x.items.pageInfo.hasNextPage;d.cursor=x.items.pageInfo.endCursor;if(x.fields.pageInfo.hasNextPage||x.items.nodes.some((v:J)=>v.fieldValues.pageInfo.hasNextPage))d.notice=t("Some project fields were truncated by the server. Only loaded single-select fields can be edited.");return d;
}
export async function saveHubRelease(c: HubAccess, input: HubReleaseInput, previous?: HubItem) {
  if (!input.tag.trim() || !input.name.trim()) throw new Error(t("A tag and release name are required."));
  if (c.target.provider === "gitlab" && (input.draft || input.prerelease)) throw new Error(t("GitLab releases are published immediately; GitHub-style drafts and prereleases are unavailable."));
  if (previous) { if(input.tag.trim()!==previous.data.tag_name)throw new Error(t("The existing release tag cannot be changed here.")); const fresh = await hubDetail(c,"releases",previous); if (fresh.item.data.updated_at !== previous.data.updated_at || fresh.item.body!==previous.body || fresh.item.title!==previous.title) throw new Error(t("This item changed on the server. Refresh before saving.")); }
  const body = c.target.provider === "github" ? {tag_name:input.tag.trim(),name:input.name.trim(),body:input.body,target_commitish:input.target.trim()||undefined,draft:input.draft,prerelease:input.prerelease} : {tag_name:input.tag.trim(),name:input.name.trim(),description:input.body,...(!previous&&input.target.trim()?{ref:input.target.trim()}:{})};
  if(previous)await raw(c,`${repo(c)}/releases/${enc(previous.id)}`,c.target.provider==="github"?"PATCH":"PUT",body);else await create(c,`${repo(c)}/releases`,body);
}
export async function deleteHubItem(c: HubAccess, section: "releases"|"gists", item: HubItem) { const fresh=await hubDetail(c,section,item); if(section==="gists"&&!fresh.item.editable)throw new Error(t("Only items owned by this account can be deleted.")); if(fresh.item.data.updated_at!==item.data.updated_at||fresh.item.title!==item.title||fresh.item.body!==item.body)throw new Error(t("This item changed on the server. Refresh before saving.")); await raw(c,section==="releases"?`${repo(c)}/releases/${enc(item.id)}`:`${c.apiBase}/${c.target.provider==="github"?"gists":"snippets"}/${enc(item.id)}`,"DELETE"); }
export async function saveHubGist(c: HubAccess, input: HubGistInput, previous?: HubDetail) {
  if(!input.files.length||input.files.some(f=>!f.name.trim()||!f.content.trim())||new Set(input.files.map(f=>f.name.trim())).size!==input.files.length)throw new Error(t("Each file needs a unique name and content."));
  if(previous&&(!previous.item.editable||previous.files.some(f=>f.truncated)||previous.item.data.truncated))throw new Error(t("Only complete files owned by this account can be edited."));
  if(previous){const fresh=await hubDetail(c,"gists",previous.item);if(fresh.item.data.updated_at!==previous.item.data.updated_at||JSON.stringify(fresh.files)!==JSON.stringify(previous.files))throw new Error(t("This item changed on the server. Refresh before saving."));}
  if(c.target.provider==="github"){const files:Record<string,unknown>=Object.fromEntries(input.files.map(f=>[f.name.trim(),{content:f.content}]));if(previous)for(const f of previous.files)if(!input.files.some(n=>n.name.trim()===f.name))files[f.name]=null;const body={description:input.description,...(!previous?{public:input.public}:{}),files};if(previous)await raw(c,`${c.apiBase}/gists/${enc(previous.item.id)}`,"PATCH",body);else await create(c,`${c.apiBase}/gists`,body);}
  else{const files=input.files.map(f=>({file_path:f.name.trim(),content:f.content,...(previous?{action:previous.files.some(p=>p.name===f.name.trim())?"update":"create"}:{})}));if(previous)for(const f of previous.files)if(!input.files.some(n=>n.name.trim()===f.name))files.push({file_path:f.name,content:"",action:"delete"});const body={title:input.description.trim()||input.files[0].name,description:input.description,...(!previous?{visibility:input.public?"public":"private"}:{}),files};if(previous)await raw(c,`${c.apiBase}/snippets/${enc(previous.item.id)}`,"PUT",body);else await create(c,`${c.apiBase}/snippets`,body);}
}
export const starHubGist=(c:HubAccess,item:HubItem,starred:boolean)=>{if(c.target.provider!=="github")throw new Error(t("GitLab snippets do not support stars."));return raw(c,`${c.apiBase}/gists/${enc(item.id)}/star`,starred?"PUT":"DELETE");};
export async function moveHubProjectItem(c:HubAccess,detail:HubDetail,row:HubProjectRow,field:HubProjectField,option:string){if(!field.options.some(o=>o.id===option)||!detail.fields.some(f=>f.id===field.id)||!detail.rows.some(r=>r.id===row.id))throw new Error(t("Select a loaded project field and item."));if(c.target.provider==="github"){await graphql(c,"mutation($input:UpdateProjectV2ItemFieldValueInput!){updateProjectV2ItemFieldValue(input:$input){projectV2Item{id}}}",{input:{projectId:detail.item.id,itemId:row.id,fieldId:field.id,value:{singleSelectOptionId:option}}});}else{const fresh=await request<J>(c,`${repo(c)}/issues/${enc(row.id)}`);const boardLabels=field.options.filter(o=>!o.id.startsWith("__")).map(o=>o.name);const label=field.options.find(o=>o.id===option&&!o.id.startsWith("__"))?.name;await raw(c,`${repo(c)}/issues/${enc(row.id)}`,"PUT",{remove_labels:(fresh.labels??[]).filter((l:string)=>boardLabels.includes(l)&&l!==label).join(","),...(label?{add_labels:label}:{}),state_event:option==="__closed"?"close":"reopen"});}}
export async function addHubProjectIssue(c:HubAccess,detail:HubDetail,issueURL:string,option?:string){const u=hubSafeURL(c,issueURL);if(!u)throw new Error(t("Enter an issue URL from the connected server."));const parsed=new URL(u);const match=parsed.pathname.match(c.target.provider==="github"?/^\/([^/]+)\/([^/]+)\/issues\/(\d+)\/?$/:/^\/(.+)\/-\/issues\/(\d+)\/?$/);if(!match)throw new Error(t("Enter a full issue URL."));if(c.target.provider==="github"){const issue=await request<J>(c,`${c.apiBase}/repos/${enc(match[1])}/${enc(match[2])}/issues/${match[3]}`);if(!issue.node_id||issue.pull_request)throw new Error(t("Select an issue rather than a pull request."));await graphql(c,"mutation($input:AddProjectV2ItemByIdInput!){addProjectV2ItemById(input:$input){item{id}}}",{input:{projectId:detail.item.id,contentId:issue.node_id}});}else{if(decodeURIComponent(match[1])!==c.target.path)throw new Error(t("Select an issue from this board's repository."));const field=detail.fields[0];if(!field)throw new Error(t("Refresh the board before adding an issue."));const x=await request<J>(c,`${repo(c)}/issues/${match[2]}`);const row:HubProjectRow={id:String(x.iid),title:x.title,body:"",url:u,contentID:String(x.id),statuses:{},labels:x.labels??[]};await moveHubProjectItem(c,{...detail,rows:[...detail.rows,row]},row,field,option??"__open");}}
