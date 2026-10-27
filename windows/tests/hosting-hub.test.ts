import { afterEach, describe, expect, it, vi } from "vitest";
import { hubPage, hubDetail, hubSafeURL, hubError, saveHubRelease, deleteHubItem, moveHubProjectItem, addHubProjectIssue, HostingHubStore, accounts, hubBoardIssueQuery, HubUncertainWriteError, HubProjectPermissionError, findTarget, hubProjectColumns, type HubAccess, type HubDetail, type HubItem } from "@/entities/hosting";
import { ipc } from "@/shared/api";
const c=(provider:"github"|"gitlab"="github"):HubAccess=>({target:{provider,host:provider==="github"?"github.com":"gitlab.test",path:"team/repo",remote:"origin"},token:"fixture-token",apiBase:provider==="github"?"https://api.github.com":"https://gitlab.test/api/v4",me:"me"});
const response=(x:unknown,status=200)=>({status,body:status===204?"":JSON.stringify(x)});
const item=(data:Record<string,unknown>={}):HubItem=>({id:"1",title:"Release",subtitle:"v1",body:"Notes",url:"https://github.com/team/repo/releases/tag/v1",data:{tag_name:"v1",updated_at:"a",...data}});
const detail=(i=item()):HubDetail=>({item:i,members:[],repositories:[],assets:[],fields:[],rows:[],more:false});
afterEach(()=>vi.restoreAllMocks());
describe("hosting workspace endpoints",()=>{
 it("keeps organization icons from list and detail responses without extra requests", async () => {
   const listAvatar = "https://avatars.githubusercontent.com/u/5?v=4";
   const detailAvatar = "https://avatars.githubusercontent.com/u/5?v=5";
   const http = vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => response(
     url.includes("/user/orgs?") ? [{id:5, login:"team", avatar_url:listAvatar}]
       : url.includes("/repos?") ? [] : {name:"Team", avatar_url:detailAvatar}
   ));
   const page = await hubPage(c(), "organizations");
   expect(page.items[0].avatarURL).toBe(listAvatar);
   expect((await hubDetail(c(), "organizations", page.items[0])).item.avatarURL).toBe(detailAvatar);
   expect(http).toHaveBeenCalledTimes(3);
   expect(http.mock.calls.every(([method]) => method === "GET")).toBe(true);
 });
 it("resolves GitLab group icons and retains them when detail omits the field", async () => {
   let profile: Record<string, unknown> = {name:"Team"};
   vi.spyOn(ipc, "http").mockImplementation(async (_method, url) => response(
     url.includes("/groups?") ? [{id:5, name:"Team", full_path:"team", avatar_url:"/uploads/group/avatar/5/team.png"}]
       : url.includes("/projects?") ? [] : profile
   ));
   const page = await hubPage(c("gitlab"), "organizations");
   expect(page.items[0].avatarURL).toBe("https://gitlab.test/uploads/group/avatar/5/team.png");
   expect((await hubDetail(c("gitlab"), "organizations", page.items[0])).item.avatarURL).toBe(page.items[0].avatarURL);
   profile = {name:"Team", avatar_url:null};
   expect((await hubDetail(c("gitlab"), "organizations", page.items[0])).item.avatarURL).toBeNull();
 });
 it("rejects unsafe organization icon addresses and keeps initials available", async () => {
   const values = ["javascript:alert(1)", "data:image/png;base64,test", "http://github.com/team.png", "https://me:secret@github.com/team.png", "https://evil.test/team.png", "//avatars.githubusercontent.com/u/5", "", null];
   vi.spyOn(ipc, "http").mockResolvedValue(response(values.map((avatar_url, id) => ({id, login:`team-${id}`, avatar_url}))));
   const page = await hubPage(c(), "organizations");
   expect(page.items).toHaveLength(values.length);
   expect(page.items.every(item => item.avatarURL === null)).toBe(true);
 });
 it("switches explicitly between repository-owner and personal Projects without affecting releases",async()=>{const saved=accounts.accounts,account={id:"gh",provider:"github" as const,server:"https://github.com",username:"me",name:null,avatarURL:null};accounts.accounts=[account];vi.spyOn(accounts,"token").mockResolvedValue("fixture-token");const http=vi.spyOn(ipc,"http").mockImplementation(async(_method,url,_headers,body)=>{if(url.endsWith("/graphql")){const query=JSON.parse(body!);return response({data:query.query.includes("user(login:$owner)")?{user:{projectsV2:{nodes:[{id:"personal",title:"My roadmap"}],pageInfo:{}}}}:{repository:{owner:{projectsV2:{nodes:[],pageInfo:{}}}}}});}return response([]);});try{const hub=new HostingHubStore({path:"fixture",target:c().target,hostingAccount:account});await hub.activate("projects");expect(hub.projectOwner).toBe("team");expect(hub.items).toHaveLength(0);await hub.selectProjectScope("personal");expect(hub.projectOwner).toBe("me");expect(hub.items[0].id).toBe("personal");const personal=JSON.parse(http.mock.calls[1][3]!);expect(personal.variables.owner).toBe("me");expect(personal.query).toContain("user(login:$owner)");await hub.activate("releases");expect(http.mock.calls[2][1]).toContain("/repos/team/repo/releases");expect(http.mock.calls.every(([method,, ,body])=>method==="GET"||!JSON.parse(body!).query.includes("mutation"))).toBe(true);}finally{accounts.accounts=saved;}});
 it("ignores a delayed owner-project response after switching to personal Projects",async()=>{const saved=accounts.accounts,account={id:"gh",provider:"github" as const,server:"https://github.com",username:"me",name:null,avatarURL:null};accounts.accounts=[account];vi.spyOn(accounts,"token").mockResolvedValue("fixture-token");let finish!:(value:ReturnType<typeof response>)=>void;vi.spyOn(ipc,"http").mockImplementationOnce(()=>new Promise(resolve=>{finish=resolve;})).mockResolvedValue(response({data:{user:{projectsV2:{nodes:[{id:"personal",title:"Personal"}],pageInfo:{}}}}}));try{const hub=new HostingHubStore({path:"fixture",target:c().target,hostingAccount:account});const old=hub.activate("projects");await vi.waitFor(()=>expect(finish).toBeDefined());await hub.selectProjectScope("personal");finish(response({data:{repository:{owner:{projectsV2:{nodes:[{id:"old",title:"Old owner"}],pageInfo:{}}}}}}));await old;expect(hub.items.map(item=>item.id)).toEqual(["personal"]);expect(hub.error).toBeNull();}finally{accounts.accounts=saved;}});

 it("groups a project by Status and keeps unassigned or removed statuses visible exactly once",()=>{const d=detail();d.fields=[{id:"priority",name:"Priority",options:[{id:"P1",name:"High"}]},{id:"status",name:"Status",options:[{id:"todo",name:"Todo"},{id:"done",name:"Done"}]}];d.rows=[{id:"1",title:"Todo",body:"",url:"",contentID:"1",statuses:{status:"todo"}},{id:"2",title:"No status",body:"",url:"",contentID:"2",statuses:{}},{id:"3",title:"Deleted status",body:"",url:"",contentID:"3",statuses:{status:"removed"}}];const columns=hubProjectColumns(d);expect(columns.map(column=>[column.id,column.rows.length])).toEqual([["",2],["todo",1],["done",0]]);expect(columns.flatMap(column=>column.rows.map(row=>row.id)).sort()).toEqual(["1","2","3"]);expect(hubProjectColumns(d,"priority").map(column=>column.id)).toEqual(["","P1"]);});

 it("resolves connected gitch SSH aliases to canonical GitHub and GitLab API targets",async()=>{
   const saved=accounts.accounts;
   accounts.accounts=[{id:"gh",provider:"github",server:"https://github.com",username:"jjunhaa0211",name:null,avatarURL:null},{id:"gl",provider:"gitlab",server:"https://gitlab.smart-fact.co.kr",username:"hyginopjh",name:null,avatarURL:null}];
   try {
     const target=findTarget(["origin"],{origin:"git@github-jjunhaa0211:Gitrochi/Gitrochi.git"},[],accounts.sshHostAliases)!;
     expect(target).toMatchObject({provider:"github",host:"github.com",path:"Gitrochi/Gitrochi"});
     expect(findTarget(["origin"],{origin:"ssh://git@gitlab-hyginopjh:2222/group/repo.git"},["gitlab.smart-fact.co.kr"],accounts.sshHostAliases)).toMatchObject({provider:"gitlab",host:"gitlab.smart-fact.co.kr",path:"group/repo"});
     expect(findTarget(["origin"],{origin:"https://github-jjunhaa0211/owner/repo.git"},[],accounts.sshHostAliases)).toBeNull();
     expect(findTarget(["origin"],{origin:"git@github-unknown:owner/repo.git"},[],accounts.sshHostAliases)).toBeNull();
     vi.spyOn(accounts,"token").mockResolvedValue("fixture-token");
     const http=vi.spyOn(ipc,"http").mockResolvedValue(response([{id:1,tag_name:"v0.3.11",name:"Gitrochi"}]));
     const hub=new HostingHubStore({path:"fixture",target,hostingAccount:accounts.accounts[0]});
     await hub.activate("releases"); expect(hub.error).toBeNull();expect(hub.items[0].title).toBe("Gitrochi");expect(http.mock.calls[0][1]).toContain("https://api.github.com/repos/Gitrochi/Gitrochi/releases?");
   } finally { accounts.accounts=saved; }
 });
 it("does not guess a gitch alias shared by two different servers",()=>{const saved=accounts.accounts;accounts.accounts=[{id:"1",provider:"gitlab",server:"https://gitlab.one.test",username:"me",name:null,avatarURL:null},{id:"2",provider:"gitlab",server:"https://gitlab.two.test",username:"me",name:null,avatarURL:null}];try{expect(accounts.sshHostAliases["gitlab-me"]).toBeUndefined();}finally{accounts.accounts=saved;}});
 it("offers project permission recovery and clears it after a successful retry",async()=>{const saved=accounts.accounts;const account={id:"gh",provider:"github" as const,server:"https://github.com",username:"me",name:null,avatarURL:null};accounts.accounts=[account];vi.spyOn(accounts,"token").mockResolvedValue("fixture-token");const http=vi.spyOn(ipc,"http").mockResolvedValueOnce(response({errors:[{type:"INSUFFICIENT_SCOPES",message:"required scopes read:project"}]})).mockResolvedValue(response({data:{repository:{owner:{projectsV2:{nodes:[],pageInfo:{}}}}}}));try{const hub=new HostingHubStore({path:"fixture",target:c().target,hostingAccount:account});await hub.activate("projects");expect(hub.projectPermissionRequired).toBe(true);expect(hub.error).toContain("Connect project access");await hub.load();expect(hub.projectPermissionRequired).toBe(false);expect(hub.error).toBeNull();expect(http).toHaveBeenCalledTimes(2);}finally{accounts.accounts=saved;}});

 it("paginates releases and preserves draft/asset metadata",async()=>{const http=vi.spyOn(ipc,"http").mockImplementation(async(_m,url)=>response(url.includes("per_page")?Array.from({length:30},(_,id)=>({id,name:`R${id}`,tag_name:`v${id}`,draft:true})):({id:1,name:"R1",tag_name:"v1",assets:[{id:2,name:"App.zip",size:42,download_count:5,browser_download_url:"https://github.com/team/repo/releases/download/v1/App.zip"}]})));const p=await hubPage(c(),"releases",2);expect(p.more).toBe(true);expect(p.items[0].subtitle).toContain("draft");expect(http.mock.calls[0][1]).toContain("page=2");expect((await hubDetail(c(),"releases",item())).assets[0]).toMatchObject({size:42,downloads:5});});
 it("queries Projects v2 using cursors and parses single-select fields", async () => {
   const http = vi.spyOn(ipc, "http").mockImplementation(async (_m, _u, _h, b) => {
     const x = JSON.parse(b!);
     const node = {id:"P", title:"Roadmap", fields:{nodes:[{id:"F",name:"Status",options:[{id:"O",name:"Done"}]}], pageInfo:{}}, items:{nodes:[{id:"I",content:{id:"C",title:"Issue"},fieldValues:{nodes:[{optionId:"O",field:{id:"F"}}],pageInfo:{}}}],pageInfo:{hasNextPage:true,endCursor:"next"}}};
     const repository = {owner:{projectsV2:{nodes:[{id:"P",number:1,title:"Roadmap"}],pageInfo:{hasNextPage:true,endCursor:"next"}}}};
     return response({data:x.query.includes("node(id:") ? {node} : {repository}});
   });
   expect((await hubPage(c(),"projects",1,"before")).cursor).toBe("next");
   expect(JSON.parse(http.mock.calls[0][3]!).variables.cursor).toBe("before");
   const d=await hubDetail(c(),"projects",item());
   expect(d.fields[0].options[0].name).toBe("Done"); expect(d.rows[0].statuses.F).toBe("O"); expect(d.more).toBe(true);
 });
 it("supports account-only user projects",async()=>{const http=vi.spyOn(ipc,"http").mockResolvedValue(response({data:{user:{projectsV2:{nodes:[],pageInfo:{hasNextPage:false}}}}}));const a=c();a.target.path="me/workspace";await hubPage(a,"projects");expect(JSON.parse(http.mock.calls[0][3]!).query).toContain("user(login:$owner)");});
 it("reports missing Projects scopes once without leaking raw GraphQL fields",async()=>{
   vi.spyOn(ipc,"http").mockResolvedValue(response({data:{repository:null},errors:[{type:"INSUFFICIENT_SCOPES",message:"The id field requires read:project but token has repo"},{message:"The title field requires read:project"}]}));
   await expect(hubPage(c(),"projects")).rejects.toBeInstanceOf(HubProjectPermissionError);
   await expect(hubPage(c(),"projects")).rejects.toThrow("Connect project access");
   try { await hubPage(c(),"projects"); } catch(error) { expect(String(error)).not.toContain("id field"); expect(String(error)).not.toContain("title field"); }
 });
 it("keeps unrelated GraphQL failures distinct from missing scopes",async()=>{vi.spyOn(ipc,"http").mockResolvedValue(response({errors:[{message:"server internal exception"}]}));try{await hubPage(c(),"projects");throw new Error("accepted");}catch(error){expect(error).not.toBeInstanceOf(HubProjectPermissionError);expect(String(error)).toContain("Projects could not be loaded");expect(String(error)).not.toContain("internal exception");}});
 it("loads organization repositories and member pages separately",async()=>{const http=vi.spyOn(ipc,"http").mockImplementation(async(_m,url)=>response(url.includes("/members?")?[{id:1,login:"alice"}]:url.includes("/repos?")?[{id:2,full_name:"team/repo",clone_url:"https://github.com/team/repo.git"}]:{name:"Team",description:"Org"}));const i={...item(),id:"team"};expect((await hubDetail(c(),"organizations",i,2,undefined,"members")).members[0].name).toBe("alice");expect(http.mock.calls.some(([,u])=>u.includes("page=2"))).toBe(true);expect((await hubDetail(c(),"organizations",i)).repositories[0].cloneURL).toContain("repo.git");});
 it("refuses changed remote release content before editing",async()=>{const http=vi.spyOn(ipc,"http").mockResolvedValue(response({id:1,name:"Release",tag_name:"v1",body:"Changed",updated_at:"b"}));await expect(saveHubRelease(c(),{tag:"v1",name:"Release",body:"Edit",target:"",draft:true,prerelease:false},item())).rejects.toThrow("changed on the server");expect(http.mock.calls.every(([m])=>m==="GET")).toBe(true);});
 it("makes GitLab provider differences explicit and preserves unrelated labels",async()=>{const a=c("gitlab");await expect(saveHubRelease(a,{tag:"v1",name:"Release",body:"",target:"",draft:true,prerelease:false})).rejects.toThrow("immediately");const http=vi.spyOn(ipc,"http").mockImplementation(async(m)=>response(m==="GET"?{iid:2,labels:["Todo","Done","security"]}:{}));const d=detail();d.fields=[{id:"board",name:"Column",options:[{id:"1",name:"Todo"},{id:"2",name:"Done"}]}];d.rows=[{id:"2",title:"Issue",body:"",url:"",contentID:"I",statuses:{board:"1"}}];await moveHubProjectItem(a,d,d.rows[0],d.fields[0],"2");const payload=JSON.parse(http.mock.calls.find(([m])=>m==="PUT")![3]!);expect(payload).toMatchObject({remove_labels:"Todo",add_labels:"Done"});expect(JSON.stringify(payload)).not.toContain("security");});
 it("rejects unsafe issue URLs before any API call",async()=>{const http=vi.spyOn(ipc,"http");await expect(addHubProjectIssue(c(),detail(),"https://evil.test/team/repo/issues/1")).rejects.toThrow("connected server");await expect(addHubProjectIssue(c(),detail(),"https://github.com/team/repo/pull/1")).rejects.toThrow("full issue URL");expect(http).not.toHaveBeenCalled();});
 it("adds an existing issue using its node ID",async()=>{const http=vi.spyOn(ipc,"http").mockImplementation(async(m)=>response(m==="GET"?{node_id:"ISSUE"}:{data:{addProjectV2ItemById:{item:{id:"NEW"}}}}));await addHubProjectIssue(c(),detail({...item(),id:"PROJECT"}),"https://github.com/team/repo/issues/2");expect(JSON.parse(http.mock.calls[1][3]!).variables.input).toEqual({projectId:"PROJECT",contentId:"ISSUE"});});
 it("checks context again after a read before mutation",async()=>{let current=true;const a={...c(),stillCurrent:()=>current};const http=vi.spyOn(ipc,"http").mockImplementation(async()=>{current=false;return response({node_id:"I"});});await expect(addHubProjectIssue(a,detail(),"https://github.com/team/repo/issues/1")).rejects.toThrow("changed");expect(http).toHaveBeenCalledTimes(1);});
 it("does not delete an item changed since confirmation",async()=>{const http=vi.spyOn(ipc,"http").mockResolvedValue(response({id:1,name:"Release",tag_name:"v1",body:"Notes",updated_at:"new"}));await expect(deleteHubItem(c(),item())).rejects.toThrow("changed");expect(http.mock.calls.every(([m])=>m==="GET")).toBe(true);});
 it("restricts browser URLs and redacts secrets in errors",()=>{expect(hubSafeURL(c(),"javascript:alert(1)")).toBeNull();expect(hubSafeURL(c(),"https://me:pass@github.com/x")).toBeNull();expect(hubSafeURL(c(),"https://evil.test/x")).toBeNull();expect(hubSafeURL(c(),"https://github.com/team/repo")).toBeTruthy();const text=hubError(new Error("fixture-token github_pat_abc https://me:pass@github.com/x?token=other"),"fixture-token");expect(text).not.toContain("fixture-token");expect(text).not.toContain("github_pat_abc");expect(text).not.toContain("me:pass");expect(text).not.toContain("other");});
 it("clears stale controller data when its section changes",async()=>{const source={path:null,target:null,hostingAccount:null};vi.spyOn(accounts,"token").mockResolvedValue(null);const hub=new HostingHubStore(source);hub.items=[item()];await hub.activate("organizations");expect(hub.items).toEqual([]);expect(hub.error).toContain("account");expect(hub.loading).toBe(false);});
 it("applies GitLab board scopes in the server issue query",()=>{const q=new URLSearchParams(hubBoardIssueQuery({hide_closed_list:true,labels:[{name:"security"}],assignee:{id:7},milestone:{title:"1.0"},weight:0,iteration:{id:9}},2));expect(Object.fromEntries(q)).toMatchObject({state:"opened",labels:"security",assignee_id:"7",milestone:"1.0",weight:"0",iteration_id:"9",page:"2"});});
 it("marks a lost creation response as uncertain and does not automatically retry",async()=>{const http=vi.spyOn(ipc,"http").mockRejectedValue(new Error("connection lost"));await expect(saveHubRelease(c(),{tag:"v1",name:"R",body:"",target:"",draft:true,prerelease:false})).rejects.toBeInstanceOf(HubUncertainWriteError);expect(http).toHaveBeenCalledTimes(1);});
 it("keeps a definite permission rejection distinct from an uncertain creation",async()=>{vi.spyOn(ipc,"http").mockResolvedValue(response({message:"forbidden"},403));try{await saveHubRelease(c(),{tag:"v1",name:"R",body:"",target:"",draft:true,prerelease:false});throw new Error("accepted");}catch(e){expect(e).not.toBeInstanceOf(HubUncertainWriteError);expect(String(e)).toContain("403");}});
 it("pages GitLab boards locally when the board API returns the full list",async()=>{vi.spyOn(ipc,"http").mockResolvedValue(response(Array.from({length:65},(_,id)=>({id,name:`Board ${id}`}))));const p=await hubPage(c("gitlab"),"projects",2);expect(p.items).toHaveLength(30);expect(p.items[0].id).toBe("30");expect(p.more).toBe(true);expect((await hubPage(c("gitlab"),"projects",3)).more).toBe(false);});

});

 it("keeps organization member avatars and profile links without extra requests",async()=>{const http=vi.spyOn(ipc,"http").mockImplementation(async(_m,url)=>response(url.includes("/members?")?[{id:1,login:"alice",avatar_url:"https://avatars.githubusercontent.com/u/1",html_url:"https://github.com/alice"}]:{name:"Team"}));const d=await hubDetail(c(),"organizations",{...item(),id:"team"},1,undefined,"members");expect(d.members[0]).toMatchObject({name:"alice",username:"alice",role:"Member",avatarURL:"https://avatars.githubusercontent.com/u/1",url:"https://github.com/alice"});expect(http).toHaveBeenCalledTimes(2);});
 it("preserves GitLab member names and readable roles while rejecting unsafe profile data",async()=>{vi.spyOn(ipc,"http").mockImplementation(async(_m,url)=>response(url.includes("/members/all?")?[{id:1,name:"Alice Kim",username:"alice",access_level:40,avatar_url:"javascript:alert(1)",web_url:"https://evil.test/alice"},{id:2,username:"bob",access_level:10,avatar_url:"https://gitlab.test/avatar/2",web_url:"https://gitlab.test/bob"}]:{name:"Team"}));const d=await hubDetail(c("gitlab"),"organizations",item(),1,undefined,"members");expect(d.members[0]).toMatchObject({name:"Alice Kim",username:"alice",role:"Maintainer",avatarURL:null,url:""});expect(d.members[1]).toMatchObject({name:"bob",username:"bob",role:"Guest",url:"https://gitlab.test/bob"});});
