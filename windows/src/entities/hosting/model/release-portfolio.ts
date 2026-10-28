import { Observable } from "@/shared/lib";
import { t } from "@/shared/i18n";
import { hubError, hubPage, type HubPage } from "../api/hub";
import { accounts } from "./accounts";
import { HostingHubStore, type HubSource } from "./hub";

export interface ReleaseSummary {
  status: "Not checked" | "Checking releases…" | "Ready" | "No releases" | "Access required" | "Offline" | "Check failed";
  page?: HubPage;
  checkedAt?: number;
  error?: string;
}
/** A bounded, memory-only cache cannot leak summaries across account revisions. */
export class ReleasePortfolio extends Observable {
  private entries = new Map<string, ReleaseSummary>();
  private running = 0;
  private waiting: (() => void)[] = [];
  constructor(private read: (source: HubSource) => Promise<HubPage> = async source => {
    const hub = new HostingHubStore(source);
    const access = await hub.access();
    try { return await hubPage(access, "releases"); }
    catch (error) { throw new Error(hubError(error, access.token)); }
  }) { super(); }
  key(source: HubSource) { return JSON.stringify([source.path, source.target, source.hostingAccount?.id, accounts.revision, source.hostingHubRevision]); }
  entry(source: HubSource): ReleaseSummary { return this.entries.get(this.key(source)) ?? { status: "Not checked" }; }
  async refresh(sources: HubSource[], force = false) { await Promise.all(sources.map(source => this.refreshOne(source, force))); }
  private async refreshOne(source: HubSource, force: boolean) {
    const key = this.key(source), previous = this.entries.get(key);
    if (previous?.status === "Checking releases…" || (!force && previous?.checkedAt && Date.now() - previous.checkedAt < 300_000)) return;
    this.entries.set(key, { status: "Checking releases…" }); this.emit();
    if (this.running >= 2) await new Promise<void>(resolve => this.waiting.push(resolve));
    else this.running++;
    try {
      if (key !== this.key(source)) return;
      if (!source.hostingAccount) { this.entries.set(key, { status: "Access required", checkedAt: Date.now(), error: t("Connect an account to check releases.") }); return; }
      if (typeof navigator !== "undefined" && navigator.onLine === false) { this.entries.set(key, { status: "Offline", checkedAt: Date.now() }); return; }
      const page = await this.read(source);
      if (key === this.key(source)) this.entries.set(key, { status: page.items.length ? "Ready" : "No releases", page, checkedAt: Date.now() });
    } catch (error) {
      if (key !== this.key(source)) return;
      const message = hubError(error);
      const status = /401|403|permission|token|account|access/i.test(message) ? "Access required" : /offline|network|connection|timed? ?out/i.test(message) ? "Offline" : "Check failed";
      this.entries.set(key, { status, checkedAt: Date.now(), error: message });
    } finally {
      if (this.entries.get(key)?.status === "Checking releases…") this.entries.delete(key);
      const next = this.waiting.shift();
      if (next) next(); else this.running--;
      // Do not evict a queued request, which also prevents duplicate scheduling.
      if (this.entries.size > 100) for (const [entryKey, entry] of this.entries) {
        if (this.entries.size <= 100) break;
        if (entry.status !== "Checking releases…" && entryKey !== key) this.entries.delete(entryKey);
      }
      this.emit();
    }
  }
}
export const releasePortfolio = new ReleasePortfolio();
