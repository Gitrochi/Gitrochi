import { Observable } from "@/shared/lib";
import { t } from "@/shared/i18n";
import { hubDetail, hubError, hubPage, ensureHubCurrent, type HubAccess, type HubDetail, type HubItem, type HubPage, type HubProjectRow } from "../api/hub";
import { scheduleEntries, type ProjectScheduleEntry, type ProjectScheduleSettings } from "./project-schedule";

/** A deduplicated task retains the project whose actual date is used by the portfolio. */
export interface ProjectPortfolioTask { id: string; detail: HubDetail; entry: ProjectScheduleEntry; projectNames: string[] }
const identity = (row: HubProjectRow, projectID: string): string[] => {
  if (row.kind === "draft") return [`draft:${projectID}:${row.id}`];
  let url: URL | undefined;
  try { const parsed = new URL(row.url); if (parsed.protocol === "https:") url = parsed; } catch { /* No usable content URL. */ }
  const keys = row.contentID ? [`content:${url?.hostname.toLowerCase() ?? ""}:${row.contentID}`] : [];
  if (url) { url.search = ""; url.hash = ""; url.pathname = url.pathname.replace(/\/+$/, ""); keys.push(`url:${url.toString()}`); }
  return keys.length ? keys : [`item:${projectID}:${row.id}`];
};
export function portfolioTasks(details: HubDetail[], settingsByProject: Record<string, ProjectScheduleSettings> = {}): ProjectPortfolioTask[] {
  const groups: ProjectPortfolioTask[][] = [], aliases = new Map<string, number>();
  for (const detail of [...details].sort((a, b) => a.item.id.localeCompare(b.item.id))) {
    for (const entry of scheduleEntries(detail.rows, detail.fields, settingsByProject[detail.item.id]).sort((a, b) => a.row.id.localeCompare(b.row.id))) {
      const keys = identity(entry.row, detail.item.id), matches = [...new Set(keys.map(key => aliases.get(key)).filter((value): value is number => value !== undefined))].sort((a, b) => a - b);
      const index = matches[0] ?? groups.length;
      if (index === groups.length) groups.push([]);
      for (const old of matches.slice(1)) { groups[index].push(...groups[old]); groups[old] = []; for (const [key, value] of aliases) if (value === old) aliases.set(key, index); }
      groups[index].push({ id: keys[0], detail, entry, projectNames: [detail.item.title] });
      for (const key of keys) aliases.set(key, index);
    }
  }
  const date = (task: ProjectPortfolioTask) => task.entry.invalidRange ? "99999" : task.entry.date ?? "99999";
  const compare = (a: ProjectPortfolioTask, b: ProjectPortfolioTask) => date(a).localeCompare(date(b)) || a.detail.item.id.localeCompare(b.detail.item.id) || a.entry.row.id.localeCompare(b.entry.row.id);
  return groups.filter(group => group.length).map(group => {
    const active = group.filter(task => !task.entry.completed), chosen = [...(active.length ? active : group)].sort(compare)[0];
    return { ...chosen, entry: { ...chosen.entry, completed: !active.length }, id: group.map(task => task.id).sort()[0], projectNames: [...new Set(group.flatMap(task => task.projectNames))].sort() };
  }).sort((a, b) => date(a).localeCompare(date(b)) || a.id.localeCompare(b.id));
}

export interface ProjectPortfolioReader {
  page(c: HubAccess, page: number, cursor?: string): Promise<HubPage>;
  detail(c: HubAccess, item: HubItem, page: number, cursor?: string): Promise<HubDetail>;
}
const defaultReader: ProjectPortfolioReader = {
  page: (c, page, cursor) => hubPage(c, "projects", page, cursor),
  detail: (c, item, page, cursor) => hubDetail(c, "projects", item, page, cursor),
};

/** Home reads have their own context, pagination and failures, independent of the project editor. */
export class ProjectPortfolioState extends Observable {
  projects: HubItem[] = [];
  details: HubDetail[] = [];
  selectedIDs: string[] = [];
  loading = false;
  error: string | null = null;
  projectErrors: Record<string, string> = {};
  more = false;
  private context = "";
  private generation = 0;
  private requestID = 0;
  private catalogPage = 0;
  private catalogCursor?: string;
  private itemPages = new Map<string, number>();
  private selectionEstablished = false;
  constructor(private readonly reader: ProjectPortfolioReader = defaultReader) { super(); }
  reset(context: string): void {
    this.context = context; this.generation++; this.requestID++;
    this.projects = []; this.details = []; this.selectedIDs = []; this.loading = false; this.error = null; this.projectErrors = {}; this.more = false;
    this.catalogPage = 0; this.catalogCursor = undefined; this.itemPages.clear(); this.selectionEstablished = false; this.emit();
  }
  setSelected(ids: string[]): void {
    this.requestID++; this.loading = false; this.selectionEstablished = true; this.selectedIDs = [...new Set(ids)];
    this.details = this.details.filter(detail => this.selectedIDs.includes(detail.item.id));
    this.projectErrors = Object.fromEntries(Object.entries(this.projectErrors).filter(([id]) => this.selectedIDs.includes(id)));
    for (const id of this.itemPages.keys()) if (!this.selectedIDs.includes(id)) this.itemPages.delete(id);
    this.emit();
  }
  async load(c: HubAccess, context: string, appendProjects = false): Promise<void> {
    if (this.context !== context) this.reset(context);
    if (appendProjects && this.catalogPage > 0 && !this.more) return;
    const id = ++this.requestID, generation = this.generation, access = this.guarded(c, generation, id);
    this.loading = true; this.emit();
    try {
      ensureHubCurrent(access);
      const page = await this.reader.page(access, appendProjects ? this.catalogPage + 1 : 1, appendProjects ? this.catalogCursor : undefined);
      if (!this.current(access, generation, id)) return;
      this.projects = appendProjects ? [...this.projects, ...page.items.filter(next => !this.projects.some(old => old.id === next.id))] : page.items;
      this.catalogPage = appendProjects ? this.catalogPage + 1 : 1; this.catalogCursor = page.cursor; this.more = page.more; this.error = null;
      if (!this.selectionEstablished) { this.selectedIDs = this.projects.slice(0, 3).map(item => item.id); this.selectionEstablished = true; }
      this.emit(); await this.readSelected(access, generation, id);
    } catch (error) { if (this.current(access, generation, id)) { this.error = hubError(error, c.token); this.emit(); } }
    finally { if (this.generation === generation && this.requestID === id) { this.loading = false; this.emit(); } }
  }
  async refresh(c: HubAccess, context: string): Promise<void> {
    if (this.context !== context) this.reset(context);
    const id = ++this.requestID, generation = this.generation, access = this.guarded(c, generation, id);
    this.loading = true; this.emit();
    try { await this.readSelected(access, generation, id); }
    finally { if (this.generation === generation && this.requestID === id) { this.loading = false; this.emit(); } }
  }
  async loadMoreItems(c: HubAccess, context: string, projectID: string): Promise<void> {
    if (this.context !== context) { this.reset(context); return; }
    const previous = this.details.find(detail => detail.item.id === projectID);
    if (this.loading || !this.selectedIDs.includes(projectID) || !previous?.more) return;
    const id = ++this.requestID, generation = this.generation, access = this.guarded(c, generation, id);
    this.loading = true; this.emit();
    try {
      ensureHubCurrent(access);
      const next = await this.reader.detail(access, previous.item, (this.itemPages.get(projectID) ?? 1) + 1, previous.cursor);
      if (!this.current(access, generation, id) || !this.selectedIDs.includes(projectID)) return;
      const merged = { ...next, rows: [...previous.rows, ...next.rows.filter(row => !previous.rows.some(old => old.id === row.id))] };
      this.details = this.details.map(detail => detail.item.id === projectID ? merged : detail);
      this.itemPages.set(projectID, (this.itemPages.get(projectID) ?? 1) + 1); delete this.projectErrors[projectID]; this.emit();
    } catch (error) { if (this.current(access, generation, id)) { this.projectErrors = { ...this.projectErrors, [projectID]: hubError(error, c.token) }; this.emit(); } }
    finally { if (this.generation === generation && this.requestID === id) { this.loading = false; this.emit(); } }
  }
  private async readSelected(c: HubAccess, generation: number, id: number): Promise<void> {
    const known = this.projects.filter(item => this.selectedIDs.includes(item.id));
    const missing: HubItem[] = this.selectedIDs.filter(id => !known.some(item => item.id === id)).sort().map(id => ({ id, title: "", subtitle: "", body: "", url: "", data: {} }));
    for (const item of [...known, ...missing]) {
      if (!this.current(c, generation, id)) return;
      try {
        const detail = await this.reader.detail(c, item, 1);
        if (!this.current(c, generation, id) || !this.selectedIDs.includes(item.id)) return;
        if (detail.item.id !== item.id) throw new Error(t("Project is unavailable or this account cannot access it."));
        this.details = [...this.details.filter(old => old.item.id !== item.id), detail].sort((a, b) => a.item.id.localeCompare(b.item.id));
        this.projects = this.projects.some(old => old.id === item.id) ? this.projects.map(old => old.id === item.id ? detail.item : old) : [...this.projects, detail.item];
        this.itemPages.set(item.id, 1); delete this.projectErrors[item.id]; this.emit();
      } catch (error) { if (this.current(c, generation, id)) { this.projectErrors = { ...this.projectErrors, [item.id]: hubError(error, c.token) }; this.emit(); } }
    }
  }
  private guarded(c: HubAccess, generation: number, id: number): HubAccess {
    return { ...c, stillCurrent: () => c.stillCurrent?.() !== false && this.generation === generation && this.requestID === id };
  }
  private current(c: HubAccess, generation: number, id: number): boolean {
    return this.generation === generation && this.requestID === id && c.stillCurrent?.() !== false;
  }
}
