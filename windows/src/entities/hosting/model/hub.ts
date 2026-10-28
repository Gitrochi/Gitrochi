import { accountApiBase, accountHost, type HostAccount, type RepoTarget } from "@/entities/git";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { accounts } from "./accounts";
import * as API from "../api/hub";
import type { HubOrganizationTab } from "../api/organization-management";
export interface HubSource { readonly path: string | null; readonly target: RepoTarget | null; readonly hostingAccount: HostAccount | null; readonly hostingHubRevision?: number }
/** A separate controller keeps sidebar work isolated from local Git operations. */
export class HostingHubStore extends Observable {
  section: API.HostingHubSection = "releases"; items: API.HubItem[] = []; detail: API.HubDetail | null = null;
  projectScope: "repository"|"personal" = "repository";
  projectSource: "local"|"remote" = "remote";
  get isLocalProject() { return this.section === "projects" && this.projectSource === "local"; }
  async selectProjectSource(source:"local"|"remote") { if(this.busy)return;this.projectSource=source;await this.activate("projects"); }
  projectPermissionRequired = false;
  uncertainWrite = false;
  loading = false; detailLoading = false; busy = false; error: string | null = null; notice: string | null = null;
  page = 0; cursor?: string; more = false; detailPage = 1; detailCursor?: string; tab: HubOrganizationTab = "repositories";
  requestedProjectCreation: "local"|"githubPrivate"|"githubPublic"|null = null;
  requestProjectCreation(mode:"local"|"githubPrivate"|"githubPublic") { this.requestedProjectCreation=mode;this.emit(); }
  consumeProjectCreation(mode:"local"|"githubPrivate"|"githubPublic") { if(this.requestedProjectCreation===mode){this.requestedProjectCreation=null;this.emit();} }
  requestedProjectRowID: string | null = null;
  requestProjectRow(id: string | null) { this.requestedProjectRowID = id; this.emit(); }
  consumeRequestedProjectRow(id: string) { if(this.requestedProjectRowID===id){this.requestedProjectRowID=null;this.emit();} }
  selectedAccountID: string | null = null; query = "";
  private generation = 0; private listID = 0; private detailID = 0; private context = "";
  constructor(readonly source: HubSource) { super(); }
  /** Releases belong to the open repository, so they use its account (chosen in the toolbar) rather than the hub's own pick. */
  get account() { if(this.isLocalProject)return null;if(this.section==="releases")return this.source.hostingAccount;return accounts.accounts.find(a=>a.id===this.selectedAccountID) ?? this.source.hostingAccount ?? accounts.accounts[0] ?? null; }
  get contextStamp() { return JSON.stringify([this.source.path,this.source.target,this.source.hostingHubRevision,this.account?.id,this.projectScope,this.projectSource,this.isLocalProject ? 0 : accounts.revision]); }
  get actionStamp() { return JSON.stringify([this.contextStamp,this.section,this.detail?.item.id??null,this.detailID]); }
  get provider() { if(this.isLocalProject)return "github";return this.account?.provider ?? this.source.target?.provider ?? "github"; }
  get projectRepositoryOwner() { const target=this.source.target,account=this.account; return target&&account&&accounts.candidates(target).some(value=>value.id===account.id)?target.path.split("/")[0]:null; }
  get projectEffectiveScope() { return this.projectRepositoryOwner ? this.projectScope : "personal"; }
  get projectOwner() { if(this.isLocalProject)return t("This device");return this.projectEffectiveScope === "personal" ? this.account?.username??"" : this.projectRepositoryOwner??""; }
  async selectProjectScope(scope:"repository"|"personal") { if(this.busy)return;this.projectScope=scope;await this.activate(this.section); }
  get filteredItems() { const q=this.query.trim().toLocaleLowerCase(); return q?this.items.filter(i=>`${i.title} ${i.subtitle} ${i.body}`.toLocaleLowerCase().includes(q)):this.items; }
  reset() { this.generation++;this.listID++;this.detailID++;this.items=[];this.detail=null;this.requestedProjectRowID=null;this.page=0;this.more=false;this.cursor=undefined;this.loading=false;this.detailLoading=false;this.busy=false;this.error=null;this.projectPermissionRequired=false;this.notice=null;this.uncertainWrite=false;this.emit(); }
  async activate(section: API.HostingHubSection) { const sectionChanged=this.section!==section;this.section=section;const stamp=this.contextStamp;if(sectionChanged||this.context!==stamp){this.reset();this.section=section;this.context=stamp;this.query="";this.tab=section==="organizations"?"overview":"repositories";await this.load();}else if(this.page===0&&!this.loading)await this.load(); }
  async selectAccount(id: string) { if(this.busy)return;this.selectedAccountID=id;await this.activate(this.section); }
  setQuery(value:string) {this.query=value;this.emit();}
  async access():Promise<API.HubAccess>{if(this.isLocalProject){const stamp=this.contextStamp,g=this.generation;return{local:true,target:{provider:"github",host:"local",path:"local/workspace",remote:"origin"},token:"",apiBase:"",me:"",stillCurrent:()=>this.generation===g&&this.contextStamp===stamp};}const a=this.account,stamp=this.contextStamp,g=this.generation,actual=this.source.target;if(!a)throw new Error(this.section!=="releases"?t("Connect a GitHub or GitLab account to use this workspace."):actual?t("Connect an account on {0} to use repository services.",actual.host):t("Open a repository on the selected account's server to use releases and projects."));const matchingTarget=actual&&actual.provider===a.provider&&accounts.candidates(actual).some(x=>x.id===a.id)?actual:null;const target=API.hubProjectTarget(matchingTarget,a.provider,accountHost(a),a.username,this.section==="projects"&&a.provider==="github"&&this.projectScope==="personal");const current=()=>this.generation===g&&this.contextStamp===stamp;const token=await accounts.token(a,{reportReadFailure:true});if(!current())throw new Error(t("The repository or account changed. Reopen this action."));if(!token)throw new Error(t("The selected account has no token. Reconnect it from Settings → Accounts."));return{target,token,apiBase:accountApiBase(a),me:a.username,stillCurrent:current};}
  async load(append=false) {if(this.loading||this.busy)return;const id=++this.listID,g=this.generation;this.loading=true;this.error=null;this.projectPermissionRequired=false;if(!append){this.detail=null;this.detailID++;}this.emit();let c:API.HubAccess|undefined;try{c=await this.access();const r=await API.hubPage(c,this.section,append?this.page+1:1,append?this.cursor:undefined);if(g!==this.generation||id!==this.listID||c.stillCurrent?.()===false)return;this.items=append?[...this.items,...r.items.filter(i=>!this.items.some(p=>p.id===i.id))]:r.items;this.more=r.more;this.cursor=r.cursor;this.page=append?this.page+1:1;this.notice=r.notice??null;this.uncertainWrite=false;}catch(e){if(g===this.generation&&id===this.listID){this.error=API.hubError(e,c?.token);this.projectPermissionRequired=e instanceof API.HubProjectPermissionError;}}finally{if(g===this.generation&&id===this.listID){this.loading=false;this.emit();}}}
  async select(item:API.HubItem,append=false,tab=this.tab){if(this.busy)return;const id=++this.detailID,g=this.generation;this.detailLoading=true;this.error=null;this.projectPermissionRequired=false;this.tab=tab;if(!append&&this.detail?.item.id!==item.id)this.detail=null;this.emit();let c:API.HubAccess|undefined;try{c=await this.access();const r=await API.hubDetail(c,this.section,item,append?this.detailPage+1:1,append?this.detailCursor:undefined,tab);if(g!==this.generation||id!==this.detailID||c.stillCurrent?.()===false)return;if(append&&this.detail){if(r.organization&&this.detail.organization){r.organization.teams=[...this.detail.organization.teams,...r.organization.teams.filter(v=>!this.detail!.organization!.teams.some(o=>o.id===v.id))];r.organization.invitations=[...this.detail.organization.invitations,...r.organization.invitations.filter(v=>!this.detail!.organization!.invitations.some(o=>o.id===v.id))];}r.rows=[...this.detail.rows,...r.rows.filter(v=>!this.detail!.rows.some(o=>o.id===v.id))];r.members=[...this.detail.members,...r.members.filter(v=>!this.detail!.members.some(o=>o.id===v.id))];r.repositories=[...this.detail.repositories,...r.repositories.filter(v=>!this.detail!.repositories.some(o=>o.id===v.id))];}this.detail=r;this.uncertainWrite=false;this.detailPage=append?this.detailPage+1:1;this.detailCursor=r.cursor;}catch(e){if(g===this.generation&&id===this.detailID){this.error=API.hubError(e,c?.token);this.projectPermissionRequired=e instanceof API.HubProjectPermissionError;}}finally{if(g===this.generation&&id===this.detailID){this.detailLoading=false;this.emit();}}}
  async action(work:(c:API.HubAccess)=>Promise<unknown>,refresh:"list"|"detail"="detail",expectedStamp=this.actionStamp):Promise<boolean>{
    if(expectedStamp!==this.actionStamp||this.busy||this.loading||this.detailLoading||this.uncertainWrite)return false;
    const stamp=this.actionStamp,context=this.contextStamp,g=this.generation,item=this.detail?.item;
    this.busy=true;this.error=null;this.projectPermissionRequired=false;this.emit();
    let c:API.HubAccess|undefined;let ok=false;
    try{
      const access=await this.access();
      c={...access,stillCurrent:()=>access.stillCurrent?.()!==false&&this.actionStamp===stamp};
      API.ensureHubCurrent(c);await work(c);
      if(g!==this.generation||stamp!==this.actionStamp)return false;
      ok=true;
    }catch(e){
      if(g===this.generation&&stamp===this.actionStamp){this.error=API.hubError(e,c?.token);this.projectPermissionRequired=e instanceof API.HubProjectPermissionError;this.uncertainWrite=e instanceof API.HubUncertainWriteError;}
    }finally{
      if(g===this.generation&&context===this.contextStamp){this.busy=false;this.emit();}
    }
    if(ok){if(refresh==="detail"&&item)await this.select(item);else await this.load();}
    return ok;
  }
}
