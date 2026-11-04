import { accountApiBase, accountHost, type HostAccount } from "@/entities/git";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";
import { hubError, hubPage, type HubAccess, type HubItem } from "../api/hub";
import { accounts } from "./accounts";

/** Organization discovery is independent of the selected repository and project requests. */
export class ProjectOrganizationState extends Observable {
  items: HubItem[] = [];
  loading = false;
  error: string | null = null;
  more = false;
  private account: HostAccount | null = null;
  private context = "";
  private generation = 0;
  private page = 0;
  private cursor?: string;

  activate(account: HostAccount | null, revision: number): Promise<void> {
    const context = account ? JSON.stringify([account.id, accountHost(account), revision]) : "";
    if (context === this.context) return Promise.resolve();
    this.context = context; this.account = account; this.generation++;
    this.items = []; this.loading = false; this.error = null; this.more = false; this.page = 0; this.cursor = undefined; this.emit();
    return context ? this.load() : Promise.resolve();
  }

  async load(append = false): Promise<void> {
    const account = this.account;
    if (!this.context || !account || this.loading || append && !this.more) return;
    const generation = this.generation, current = () => generation === this.generation;
    this.loading = true; this.error = null; this.emit();
    let access: HubAccess | undefined;
    try {
      const token = await accounts.token(account, { reportReadFailure: true });
      if (!current()) return;
      if (!token) throw new Error(t("The selected account has no token. Reconnect it from Settings → Accounts."));
      access = { target: { provider: account.provider, host: accountHost(account), path: `${account.username}/workspace`, remote: "origin" }, token, apiBase: accountApiBase(account), me: account.username, stillCurrent: current };
      const page = await hubPage(access, "organizations", append ? this.page + 1 : 1, append ? this.cursor : undefined);
      if (!current()) return;
      // A GitLab group is chosen by its full path, which also tells subgroups with the same name apart.
      const found = account.provider === "gitlab" ? page.items.filter(item => item.subtitle).map(item => ({ ...item, id: item.subtitle, title: item.subtitle })) : page.items;
      this.items = append ? [...this.items, ...found.filter(item => !this.items.some(old => old.id.toLowerCase() === item.id.toLowerCase()))] : found;
      this.page = append ? this.page + 1 : 1; this.more = page.more; this.cursor = page.cursor;
    } catch (error) {
      if (current()) this.error = `${account.provider === "gitlab" ? t("Groups could not be loaded. Repository boards are still available.") : t("Organizations could not be loaded. Your personal projects are still available.")}\n${hubError(error, access?.token)}`;
    } finally {
      if (current()) { this.loading = false; this.emit(); }
    }
  }
}
