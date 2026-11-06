import { accountApiBase, accountHost, type HostAccount } from "@/entities/git";
import { accounts, accountWorkPage, HostingError, markAccountWorkRead, type AccountWorkItem, type AccountWorkKind, type ReviewAccess } from "@/entities/hosting";
import { Observable } from "@/shared/lib";

/** `expired`: the server refused the saved sign-in (401), or there is no saved sign-in to send */
export type AccountWorkFailure = { kind: "expired" } | { kind: "unreachable" } | { kind: "message"; text: string };

/** The transport rejects with plain text when the request never got an answer; everything else is an Error */
export const accountWorkFailure = (error: unknown): AccountWorkFailure =>
  error instanceof HostingError && error.status === 401
    ? { kind: "expired" }
    : error instanceof Error
      ? { kind: "message", text: error.message }
      : { kind: "unreachable" };

/**
 * One list of the Account page: the inbox of the chosen account, or one category of its open work. The page owns it,
 * so its tab row can mark the whole inbox as read and its Refresh reloads the section that shows.
 * (macOS: AccountWorkModel)
 */
export class AccountWorkModel extends Observable {
  /** The category of My work */
  kind: Exclude<AccountWorkKind, "inbox"> = "mine";
  items: AccountWorkItem[] = [];
  page = 0;
  more = false;
  busy = false;
  failure: AccountWorkFailure | null = null;
  /** When the rows were read (seconds), for "Showing data from 12m ago" under a failed refresh */
  loadedAt: number | null = null;
  selectedID: string | null = null;
  private scope = "";
  private generation = 0;

  constructor(readonly inbox: boolean) {
    super();
  }

  /** What "Mark all as read" covers: the loaded rows the server can mark */
  get unread() {
    return this.items.filter((item) => item.unread && item.readID);
  }

  /** Another account, category or sign-in starts from nothing; the same one refreshes in place */
  open(scope: string) {
    if (scope === this.scope) return;
    this.scope = scope;
    this.generation++;
    this.items = [];
    this.page = 0;
    this.more = false;
    this.busy = false;
    this.failure = null;
    this.loadedAt = null;
    this.selectedID = null;
    this.emit();
  }

  cancel() {
    this.generation++;
    this.busy = false;
    this.emit();
  }

  select(id: string) {
    this.selectedID = id;
    this.emit();
  }

  setKind(kind: Exclude<AccountWorkKind, "inbox">) {
    this.kind = kind;
    this.emit();
  }

  /** Runs one request with the account's saved sign-in; a late answer for another account or category is dropped */
  private async run(account: HostAccount, work: (access: ReviewAccess, current: () => boolean) => Promise<void>) {
    const id = ++this.generation, revision = accounts.revision, opened = this.scope;
    const current = () => this.generation === id && this.scope === opened && accounts.revision === revision;
    this.busy = true;
    this.failure = null;
    this.emit();
    try {
      const token = await accounts.token(account, { reportReadFailure: true });
      if (!current()) return;
      if (!token) {
        this.failure = { kind: "expired" };
        return;
      }
      await work({ target: { provider: account.provider, remote: "", host: accountHost(account), path: "" }, token, apiBase: accountApiBase(account), me: account.username, stillCurrent: current }, current);
    } catch (error) {
      if (current()) this.failure = accountWorkFailure(error);
    } finally {
      if (this.generation === id) {
        this.busy = false;
        this.emit();
      }
    }
  }

  load(account: HostAccount, append = false) {
    return this.run(account, async (access, current) => {
      const next = append ? this.page + 1 : 1;
      const result = await accountWorkPage(access, this.inbox ? "inbox" : this.kind, next, account.id);
      if (!current()) return;
      this.items = append ? [...this.items, ...result.items.filter((item) => !this.items.some((old) => old.id === item.id))] : result.items;
      this.page = next;
      this.more = result.more;
      this.loadedAt = Date.now() / 1000;
    });
  }

  read(item: AccountWorkItem, account: HostAccount) {
    return this.busy ? Promise.resolve() : this.mark([item], account);
  }

  /** One request per notification, the same one a single row sends; it stops at the first that fails */
  readAll(account: HostAccount) {
    return this.busy ? Promise.resolve() : this.mark(this.unread, account);
  }

  private mark(rows: AccountWorkItem[], account: HostAccount) {
    return this.run(account, async (access, current) => {
      for (const row of rows) {
        await markAccountWorkRead(access, row, account.id);
        if (!current()) return;
        this.items = this.items.map((item) => (item.id === row.id ? { ...item, unread: false } : item));
        this.emit();
      }
    });
  }
}
