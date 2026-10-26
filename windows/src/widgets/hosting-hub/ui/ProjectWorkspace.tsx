import { useState } from "react";
import { ExternalLink, Columns3, List, Circle, Plus } from "lucide-react";
import { hubProjectColumns, moveHubProjectItem, addHubProjectIssue, type HubAccess, type HubDetail, type HubProjectRow } from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button } from "@/shared/ui";

type Ask = (title:string,body:string,action:(c:HubAccess)=>Promise<unknown>)=>void;
export function ProjectWorkspace({detail,locked,gitlab,open,safe,ask}:{detail:HubDetail;locked:boolean;gitlab:boolean;open:(url:string)=>void;safe:(url:string)=>boolean;ask:Ask}) {
  const [layout,setLayout]=useState<"board"|"list">("board"),[group,setGroup]=useState(""),[issueURL,setIssueURL]=useState("");
  const field=detail.fields.find(value=>value.id===group)??detail.fields.find(value=>/^(status|상태)$/i.test(value.name))??detail.fields[0];
  const columns=hubProjectColumns(detail,field?.id);
  const card=(row:HubProjectRow)=><article className="project-card" key={row.id}>
    <div className="project-card-title"><Circle size={13}/><strong>{row.title}</strong>{safe(row.url)&&<Button size="small" tip={t("Open in browser")} onClick={()=>open(row.url)}><ExternalLink size={12}/></Button>}</div>
    {row.body&&<p className="project-card-description">{row.body.slice(0,1200)}</p>}
    <div className="project-card-fields">{detail.fields.map(value=><label key={value.id}><span>{value.name}</span><select className="select" disabled={locked||!row.contentID} value={row.statuses[value.id]??""} onChange={event=>{const option=event.target.value;ask(t("Change project status?"),`${row.title}\n${value.name}: ${value.options.find(item=>item.id===option)?.name}`,c=>moveHubProjectItem(c,detail,row,value,option));}}><option value="" disabled>{t("Not set")}</option>{value.options.map(option=><option key={option.id} value={option.id}>{option.name}</option>)}</select></label>)}</div>
  </article>;
  return <div className="project-workspace"><div className="project-toolbar"><div className="project-view-switch" role="group" aria-label={t("Project view")}><Button size="small" kind={layout==="board"?"primary":undefined} onClick={()=>setLayout("board")}><Columns3 size={13}/>{t("Board")}</Button><Button size="small" kind={layout==="list"?"primary":undefined} onClick={()=>setLayout("list")}><List size={13}/>{t("List")}</Button></div><span className="hint">{t("{0} loaded items",detail.rows.length)}</span>{field&&<label className="project-group"><span>{t("Group by")}</span><select className="select" aria-label={t("Group by")} value={field.id} onChange={event=>setGroup(event.target.value)}>{detail.fields.map(value=><option key={value.id} value={value.id}>{value.name}</option>)}</select></label>}</div>
    {!detail.fields.length&&<p className="hint">{t("No editable single-select fields. Add a Status field in the project to move items here.")}</p>}
    {!detail.rows.length?<div className="project-empty"><Columns3 size={28}/><strong>{t("This project has no loaded items.")}</strong><span>{t("Add an existing issue below or manage the project in GitHub.")}</span></div>:layout==="board"?<div className="project-board" aria-label={t("Project board")}>{columns.map((column,index)=><section className="project-column" key={column.id} style={{"--project-color":["#7d6ce8","#5b8def","#df9b46","#47a68c","#c275b8","#5b9fae"][index%6]} as React.CSSProperties}><header><span className="project-status-dot"/><strong>{column.title}</strong><span className="project-count">{column.rows.length}</span></header><div className="project-column-cards">{column.rows.map(card)}{!column.rows.length&&<p className="project-column-empty">{t("No items")}</p>}</div></section>)}</div>:<div className="project-list">{detail.rows.map(card)}</div>}
    {layout==="board"&&columns.length>1&&<span className="hint">{t("Scroll horizontally to see more columns.")}</span>}
    <div className="project-add"><input className="input" aria-label={t("Issue URL")} placeholder={t("Issue URL")} disabled={locked} value={issueURL} onChange={event=>setIssueURL(event.target.value)}/><Button disabled={locked||!issueURL.trim()} onClick={()=>{const url=issueURL;ask(gitlab?t("Move issue to the Open column?"):t("Add issue to project?"),gitlab?`${url}\n${t("This reopens the issue and removes its board column labels.")}`:url,c=>addHubProjectIssue(c,detail,url));}}><Plus size={13}/>{t("Add issue")}</Button></div>
  </div>;
}
