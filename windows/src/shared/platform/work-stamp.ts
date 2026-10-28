import { git } from "./git";

/** Hash tracked working contents locally; untracked content cannot be certified. */
export async function worktreeStamp(repo: string): Promise<{ head: string | null; stamp: string }> {
  const headResult = await git(["rev-parse", "--verify", "HEAD"], repo, { ok: [0, 128] });
  const head = headResult.status === 0 ? headResult.stdout.trim() : null;
  const [diff, status, flags] = await Promise.all([
    git(["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--binary", ...(head ? [head] : ["--cached"]), "--"], repo),
    git(["status", "--porcelain=v2", "-z", "--untracked-files=normal", "--ignore-submodules=none"], repo),
    git(["ls-files", "-v", "-z"], repo),
  ]);
  const unstaged = head ? "" : (await git(["diff", "--no-ext-diff", "--no-textconv", "--binary", "--"], repo)).stdout;
  const bytes = new TextEncoder().encode((head ?? "") + "\0" + diff.stdout + unstaged + "\0" + status.stdout);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const stamp = [...new Uint8Array(digest)].map(value => value.toString(16).padStart(2, "0")).join("");
  const hidden = flags.stdout.split("\0").some(row => row.startsWith("S ") || /^[a-z] /.test(row));
  const submodule = status.stdout.split("\0").some(row => /^[12] /.test(row) && /^S.*[MU]/.test(row.split(" ")[2] ?? ""));
  return { head, stamp: hidden || submodule ? "uncertified:" + stamp : status.stdout.split("\0").some(row => row.startsWith("? ")) ? "untracked:" + stamp : stamp };
}
