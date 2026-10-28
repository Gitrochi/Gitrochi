import { ipc } from "@/shared/api";
import { tools } from "./tools";

/** Commits indexed per background pass, so a very large history fills in over several passes. */
const passLimit = 20_000;

export type IndexSearchScope = "commits" | "files" | "code";

type Result = Record<string, unknown>;

/**
 * The shared SQLite repository index (crates/gitrochi-index) through the Tauri backend.
 * It answers the search bar's deeper step from the database instead of running git log.
 * macOS: macos/Sources/Core/RepoIndex.swift.
 */
class RepoIndex {
  private running = new Set<string>();
  private again = new Set<string>();

  /** Sends one command; null when the index answered with an error, so callers fall back to git. */
  async call(command: string, repo: string, args: Record<string, unknown> = {}): Promise<Result | null> {
    try {
      const response = await ipc.indexCall({ repo, git: tools.path("git") ?? undefined, command, args });
      return "result" in response ? response.result : null;
    } catch {
      return null;
    }
  }

  /** Brings the index up to date in the background; requests during a pass fold into one more pass. */
  refresh(repo: string): Promise<void> {
    // \\wsl$ and other network paths: SQLite's shared-memory journal needs a local disk.
    if (repo.startsWith("\\\\")) return Promise.resolve();
    if (this.running.has(repo)) {
      this.again.add(repo);
      return Promise.resolve();
    }
    this.running.add(repo);
    return (async () => {
      try {
        do {
          this.again.delete(repo);
          await this.call("sync", repo, { limit: passLimit });
        } while (this.again.has(repo));
      } finally {
        this.running.delete(repo);
      }
    })();
  }

  /**
   * The deeper search step from the index: SHAs for the commits and files scopes (the same matching
   * as git's --grep and the icase path glob), and a cached `git log -G` for code. Null when the index
   * is off, missing or behind the repository, so the caller runs git.
   */
  async searchMatches(repo: string, scope: IndexSearchScope, query: string, codePattern: string): Promise<Set<string> | null> {
    if (repo.startsWith("\\\\")) return null;
    if (scope === "code") {
      // Only when the index is current: the cache keys results by the ref tips.
      const status = await this.call("status", repo);
      if (status?.stale !== false) return null;
      const found = await this.call("cache", repo, { action: "pickaxe", text: codePattern, regex: true, limit: 1000 });
      const commits = found?.commits;
      return Array.isArray(commits) ? new Set(commits.map((c) => String((c as { sha?: unknown }).sha))) : null;
    }
    const found = await this.call("match", repo, { query, scope, limit: 20_000 });
    if (!found || found.stale !== false || !Array.isArray(found.shas)) return null;
    return new Set(found.shas.map(String));
  }
}

export const repoIndex = new RepoIndex();
