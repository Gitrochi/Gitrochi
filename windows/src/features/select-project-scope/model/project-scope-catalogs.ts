import type { HostAccount } from "@/entities/git";
import { ProjectOrganizationState } from "@/entities/hosting";
import { Observable } from "@/shared/lib";

/** One organization list per connected account, shared by the scope button and the strip that reports a failed read. macOS: ProjectScopeCatalogs. */
export class ProjectScopeCatalogs extends Observable {
  private states = new Map<string, ProjectOrganizationState>();
  private stops = new Map<string, () => void>();

  /** The account's list, empty until `load` asked for it */
  state(account: HostAccount): ProjectOrganizationState {
    let state = this.states.get(account.id);
    if (!state) {
      state = new ProjectOrganizationState();
      this.states.set(account.id, state);
      this.stops.set(account.id, state.subscribe(() => this.emit()));
    }
    return state;
  }

  /** Reads an account's organizations once per account revision. The accounts the page is not showing wait until the menu opens. */
  load(account: HostAccount, revision: number): void {
    void this.state(account).activate(account, revision);
  }

  failed(account: HostAccount | null): boolean {
    return !!account && !!this.states.get(account.id)?.error;
  }

  /** Stops every read in flight; a list that arrives late is dropped. */
  reset(revision: number): void {
    for (const state of this.states.values()) void state.activate(null, revision);
    for (const stop of this.stops.values()) stop();
    this.states.clear();
    this.stops.clear();
    this.emit();
  }
}
