import { afterEach, describe, expect, it, vi } from "vitest";
import { accounts, HostingHubStore, hubDetail, ProjectPortfolioState, saveHubProjectDraft, updateHubProjectField, type HubAccess, type HubItem } from "@/entities/hosting";
import { ipc } from "@/shared/api";

const project: HubItem = {id:"PROJECT",title:"Delivery",subtitle:"#1",body:"",url:"https://github.com/orgs/team/projects/1",data:{}};
const access: HubAccess = {target:{provider:"github",host:"github.com",path:"team/workspace",remote:"origin"},token:"fixture-only",apiBase:"https://api.github.com",me:"reader",projectOrganization:"team"};
const account = {id:"fixture",provider:"github" as const,server:"https://github.com",username:"reader",name:null,avatarURL:null};
const originalAccounts = accounts.accounts;
const response = (data: unknown, status = 200) => ({status,body:JSON.stringify(data)});
const row = (id: string, kind = "Issue", archived = false) => ({id,type:kind === "DraftIssue" ? "DRAFT_ISSUE" : kind === "PullRequest" ? "PULL_REQUEST" : kind === "REDACTED" ? "REDACTED" : "ISSUE",isArchived:archived,content:kind === "REDACTED" ? null : {__typename:kind,id:`content:${id}`,title:`Task ${id}`,body:"Original description",state:"OPEN",url:kind === "DraftIssue" ? "" : `https://github.com/team/repo/issues/${id.replace(/\D/g, "") || "1"}`,repository:{nameWithOwner:"team/repo"}},fieldValues:{nodes:[] as Record<string, unknown>[]}});
type RawRow = ReturnType<typeof row>;
const snapshot = (rows: RawRow[], more = false, cursor?: string, id = project.id) => response({data:{node:{id,title:project.title,fields:{nodes:[{id:"STATUS",name:"Status",options:[{id:"done",name:"Done"}]}],pageInfo:{}},items:{nodes:rows,pageInfo:{hasNextPage:more,endCursor:cursor}}}}});
const payload = (body?: string) => JSON.parse(body ?? "{}") as {query:string;variables:{id?:string;cursor?:string|null;input?:{itemId?:string;title?:string;draftIssueId?:string}}};
afterEach(() => {vi.restoreAllMocks();accounts.accounts = originalAccounts;});

describe("complete GitHub project snapshots", () => {
  it("loads more than two pages of archived issues, closed issues, drafts, PRs and restricted placeholders without duplicates", async () => {
    const archived = Array.from({length:100}, (_, n) => row(`archived-${n}`, "Issue", true));
    const issues = Array.from({length:100}, (_, n) => row(`issue-${n}`)); issues[0].content!.state = "CLOSED";
    const http = vi.spyOn(ipc, "http").mockImplementation(async (_m,_u,_h,body) => {
      const {cursor} = payload(body).variables;
      return !cursor ? snapshot(archived,true,"second") : cursor === "second" ? snapshot([archived[99], ...issues.slice(0,99)],true,"third") : snapshot([issues[99],row("draft","DraftIssue"),row("pr","PullRequest"),row("restricted","REDACTED"),issues[0]]);
    });
    const detail = await hubDetail(access,"projects",project);
    expect(detail.rows).toHaveLength(203); expect(new Set(detail.rows.map(item => item.id)).size).toBe(203);
    expect(detail.rows.filter(item => item.archived)).toHaveLength(100);
    expect(detail.rows.find(item => item.id === "issue-0")?.state).toBe("CLOSED");
    expect(detail.rows.slice(-3).map(item => item.kind)).toEqual(["draft","pullRequest","redacted"]);
    expect(detail).toMatchObject({more:false,cursor:undefined});
    expect(http.mock.calls.map(call => payload(call[3]).variables.cursor)).toEqual([null,"second","third"]);
    expect(payload(http.mock.calls[0][3]).query).toContain("items(first:100");
  });

  it("allows empty and duplicate-only pages when the server cursor advances", async () => {
    vi.spyOn(ipc,"http").mockImplementation(async (_m,_u,_h,body) => {
      switch (payload(body).variables.cursor) {
        case "empty": return snapshot([],true,"duplicate");
        case "duplicate": return snapshot([row("one")],true,"last");
        case "last": return snapshot([row("two")]);
        default: return snapshot([row("one")],true,"empty");
      }
    });
    expect((await hubDetail(access,"projects",project)).rows.map(item => item.id)).toEqual(["one","two"]);
  });

  it.each(["missing","stalled","cyclic"])("rejects a %s cursor instead of returning a partial complete snapshot", async mode => {
    const http = vi.spyOn(ipc,"http").mockImplementation(async (_m,_u,_h,body) => {
      const cursor = payload(body).variables.cursor;
      if (!cursor) return snapshot([row("one")],true,mode === "missing" ? undefined : "a");
      return snapshot([row(cursor)],true,mode === "stalled" || cursor === "b" ? "a" : "b");
    });
    await expect(hubDetail(access,"projects",project)).rejects.toThrow("could not be fully loaded");
    expect(http.mock.calls.length).toBeLessThanOrEqual(3);
  });

  it("keeps the previous complete snapshot when a later page fails or changes project", async () => {
    accounts.accounts = [account]; vi.spyOn(accounts,"token").mockResolvedValue(access.token);
    let failure = "", reading = false;
    vi.spyOn(ipc,"http").mockImplementation(async (_m,_u,_h,body) => {
      const {cursor} = payload(body).variables;
      if (!reading) return snapshot([row("old")]);
      if (!cursor) return snapshot([row("new-first")],true,"later");
      return failure === "wrong-project" ? snapshot([row("new-later")],false,undefined,"OTHER") : response({message:"unavailable"},500);
    });
    const hub = new HostingHubStore({path:null,target:null,hostingAccount:account}); hub.section = "projects"; hub.projectScope = "organization:team";
    await hub.select(project); expect(hub.detail?.rows.map(item => item.id)).toEqual(["old"]);
    reading = true; await hub.select(project); expect(hub.error).toBeTruthy(); expect(hub.detail?.rows.map(item => item.id)).toEqual(["old"]);
    failure = "wrong-project"; await hub.select(project); expect(hub.error).toContain("cannot access"); expect(hub.detail?.rows.map(item => item.id)).toEqual(["old"]);
  });

  it("rejects an expired context during page two and never starts page three", async () => {
    let current = true, finish!: (value:ReturnType<typeof snapshot>) => void;
    const http = vi.spyOn(ipc,"http").mockResolvedValueOnce(snapshot([row("one")],true,"second")).mockImplementationOnce(() => new Promise(resolve => {finish = resolve;}));
    const pending = hubDetail({...access,stillCurrent:() => current},"projects",project);
    await vi.waitFor(() => expect(finish).toBeDefined()); current = false; finish(snapshot([row("two")],true,"third"));
    await expect(pending).rejects.toThrow("account changed"); expect(http).toHaveBeenCalledTimes(2);
  });

  it("does not publish old account items after switching while page two is in flight", async () => {
    const second = {...account,id:"second",username:"second"}; accounts.accounts = [account,second]; vi.spyOn(accounts,"token").mockResolvedValue(access.token);
    let finish!: (value:ReturnType<typeof snapshot>) => void;
    vi.spyOn(ipc,"http").mockImplementation(async (_m,_u,_h,body) => {
      const value = payload(body);
      if (!value.query.includes("node(id:")) return response({data:{user:{projectsV2:{nodes:[{...project,id:"NEW"}],pageInfo:{}}}}});
      if (value.variables.id === "NEW") return snapshot([row("new-account")],false,undefined,"NEW");
      if (!value.variables.cursor) return snapshot([row("old-first")],true,"second");
      return new Promise(resolve => {finish = resolve;});
    });
    const hub = new HostingHubStore({path:null,target:null,hostingAccount:account}); hub.section = "projects"; hub.projectScope = "organization:team";
    const old = hub.select(project); await vi.waitFor(() => expect(finish).toBeDefined());
    await hub.selectAccount(second.id); await hub.select({...project,id:"NEW"}); finish(snapshot([row("old-second")])); await old;
    expect(hub.detail?.rows.map(item => item.id)).toEqual(["new-account"]); expect(hub.error).toBeNull();
  });

  it("retains an edited later-page issue and finds an appended draft after post-write refresh", async () => {
    accounts.accounts = [account]; vi.spyOn(accounts,"token").mockResolvedValue(access.token);
    const first = Array.from({length:100}, (_, n) => row(`archived-${n}`,"Issue",true)), later = row("later-issue"); let edited = false, created = false;
    vi.spyOn(ipc,"http").mockImplementation(async (_m,_u,_h,body) => {
      const value = payload(body);
      if (value.query.includes("updateProjectV2ItemFieldValue")) {edited = true; return response({data:{updateProjectV2ItemFieldValue:{projectV2Item:{id:later.id}}}});}
      if (value.query.includes("addProjectV2DraftIssue")) {created = true; return response({data:{addProjectV2DraftIssue:{projectItem:{id:"created"}}}});}
      if (!value.variables.cursor) return snapshot(first,true,"later");
      return snapshot([{...later,fieldValues:{nodes:edited ? [{optionId:"done",field:{id:"STATUS"}}] : []}},...(created ? [row("created","DraftIssue")] : [])]);
    });
    const hub = new HostingHubStore({path:null,target:null,hostingAccount:account}); hub.section = "projects"; hub.projectScope = "organization:team"; await hub.select(project);
    const detail = hub.detail!, selected = detail.rows.at(-1)!;
    expect(await hub.action(c => updateHubProjectField(c,detail,selected,detail.fields[0],"done"))).toBe(true);
    expect(hub.detail?.rows.at(-1)).toMatchObject({id:later.id,statuses:{STATUS:"done"}});
    expect(await hub.action(c => saveHubProjectDraft(c,hub.detail!,"New draft","Context"))).toBe(true);
    expect(hub.detail?.rows).toHaveLength(102); expect(hub.detail?.rows.at(-1)).toMatchObject({id:"created",kind:"draft"});
  });

  it("loads every Home task and retains them across refresh through the default reader", async () => {
    let refreshed = false;
    vi.spyOn(ipc,"http").mockImplementation(async (_m,_u,_h,body) => {
      const value = payload(body);
      if (!value.query.includes("node(id:")) return response({data:{organization:{projectsV2:{nodes:[project],pageInfo:{}}}}});
      if (!value.variables.cursor) return snapshot(Array.from({length:100}, (_, n) => row(`first-${n}`)),true,"later");
      return snapshot([{...row("later-draft","DraftIssue"),content:{...row("later-draft","DraftIssue").content!,title:refreshed ? "Refreshed draft" : "Original draft"}}]);
    });
    const home = new ProjectPortfolioState(); await home.load(access,"organization-home");
    expect(home.details[0].rows).toHaveLength(101); expect(home.details[0].more).toBe(false);
    refreshed = true; await home.refresh(access,"organization-home");
    expect(home.details[0].rows).toHaveLength(101); expect(home.details[0].rows.at(-1)?.title).toBe("Refreshed draft"); expect(home.projectErrors).toEqual({});
  });

  it("retains explicit raw paging for callers that supply a cursor", async () => {
    const http = vi.spyOn(ipc,"http").mockResolvedValue(snapshot([row("page-item")],true,"next"));
    const detail = await hubDetail(access,"projects",project,2,"previous");
    expect(detail).toMatchObject({more:true,cursor:"next"}); expect(http).toHaveBeenCalledTimes(1);
  });
});
