import { LedgerError } from "./backend";

type Note = { id: number; title: string; body: string; pinned: boolean; createdAt: number; updatedAt: number };
type Item = { id: string; title: string; bundle: string; output: string; status: string; project: string };
type Event = { id: number; item: string; date: string; event: string; text: string; refs: string[] };

/** Isolated sample data for the added sheets; it never reads files or writes the real Ledger. */
export class DemoLedgerExtras {
  private notes: Note[] = [];
  private items: Item[] = [];
  private events: Event[] = [];
  private roots = new Map<string, string[]>();
  private summaries = new Map<string, Record<string, unknown>>();
  private usage = { month: "2026-11", requests: 0, requestChars: 0, responseChars: 0 };

  call(method: "work" | "documents" | "notebook", args: Record<string, unknown>, now: number): unknown {
    const action = String(args.action ?? "list");
    if (method === "notebook") {
      const note = this.notes.find((row) => row.id === args.id);
      if (action === "list") return { notes: this.notes.filter((row) => `${row.title}\n${row.body}`.toLowerCase().includes(String(args.query ?? "").toLowerCase())).sort((a, b) => Number(b.pinned) - Number(a.pinned) || b.updatedAt - a.updatedAt) };
      if (action === "get") return { note };
      if (note && args.expectedUpdatedAt !== note.updatedAt) throw new LedgerError("CONFLICT", "This note changed. Reload it before saving.");
      if (action === "delete") { this.notes = this.notes.filter((row) => row.id !== args.id); return { ok: true }; }
      const saved: Note = { id: note?.id ?? Math.max(0, ...this.notes.map((row) => row.id)) + 1, title: String(args.title ?? ""), body: String(args.body ?? ""), pinned: args.pinned === true, createdAt: note?.createdAt ?? now, updatedAt: Math.max(now, (note?.updatedAt ?? 0) + 1) };
      this.notes = [...this.notes.filter((row) => row.id !== saved.id), saved];
      return { note: saved };
    }
    const project = String(args.project ?? "atlas");
    if (method === "documents") {
      if (action === "set_roots") this.roots.set(project, args.roots as string[]);
      const roots = this.roots.get(project) ?? [];
      const key = JSON.stringify([project, args.id ?? `${args.path}:${args.line}`, [`${roots[0] ?? ""}/plan.md:demo`]]);
      if (action === "usage") return { usage: this.usage };
      if (action === "summary_save") {
        this.summaries.set(key, { text: args.text, provider: args.provider, model: args.model, createdAt: now, requestChars: args.requestChars, responseChars: args.responseChars });
        this.usage.requests++; this.usage.requestChars += Number(args.requestChars ?? 0); this.usage.responseChars += Number(args.responseChars ?? 0);
      }
      if (action === "summary_get" || action === "summary_save") return { key, summary: this.summaries.get(key) ?? null, usage: this.usage };
      const entry = { id: "DOC-12", line: 3, text: "- [ ] DOC-12: Review the cache policy", heading: "Directive", definition: true, kind: "directive", status: "open", task: true, root: roots[0] ?? "", path: "plan.md", hash: "demo", changed: false };
      return { project, roots, files: roots.length ? [{ root: roots[0], path: "plan.md", hash: "demo", changed: false, modifiedAt: now, scannedAt: now }] : [], ids: roots.length ? ["DOC-12"] : [], entries: roots.length ? [entry] : [], relatedSessions: [], total: roots.length, truncated: false, warnings: [] };
    }
    const items = () => this.items.filter((row) => row.project === project);
    if (action === "list") return { project, items: items(), bundles: [], warnings: [], notes: [] };
    if (action === "detail") return { item: items().find((row) => row.id === args.item), events: this.events.filter((row) => row.item === args.item), history: [] };
    if (action === "unassigned") return { events: [] };
    if (action === "report") return { markdown: `# ${project}\n\n${items().map((row) => `- ${row.title}: ${row.status}`).join("\n")}` };
    if (action === "add_item") this.items.push({ id: String(args.item), title: String(args.title), bundle: String(args.bundle), output: String(args.output ?? ""), project, status: "planned" });
    if (action === "event" && args.event === "completed") this.items = this.items.map((row) => row.id === args.item && row.project === project ? { ...row, status: "completed" } : row);
    const record: Event = { id: this.events.length + 1, item: String(args.item), date: String(args.date), event: action === "add_item" ? "registered" : String(args.event), text: String(args.text ?? ""), refs: args.refs as string[] ?? [] };
    this.events.push(record);
    return { ok: true, eventId: record.id, results: [] };
  }
}
