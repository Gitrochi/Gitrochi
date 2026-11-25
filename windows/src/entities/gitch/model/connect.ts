import type { GitchAccount } from "./gitch";

/**
 * Connects a saved hosting account to gitch: the details come from its token, the public key is registered with the
 * same token, and only public details (name, email, server, folder) reach gitch. (macOS: GitchConnect)
 */

/** The servers of a gitch account, without the port and login notes of `gitch list` ("gitlab.x(포트 2222)") */
export function gitchHosts(account: GitchAccount): string[] {
  return account.hosts.split(",").map((h) => h.split("(")[0].trim().toLowerCase()).filter(Boolean);
}

/** The gitch account already set up for this name on this server */
export function existingGitchAccount(name: string, host: string, accounts: GitchAccount[]): GitchAccount | null {
  return accounts.find((a) => a.id === name && gitchHosts(a).includes(host.toLowerCase())) ?? null;
}

/** The login as a gitch account name; when another server's account has that name, the server's own label is added */
export function gitchAccountName(login: string, host: string, taken: GitchAccount[]): string {
  let name = login.replace(/[^A-Za-z0-9._-]/g, "-").replace(/^[^A-Za-z0-9]+/, "") || "account";
  const elsewhere = (id: string) => taken.some((a) => a.id === id && !gitchHosts(a).includes(host.toLowerCase()));
  if (!elsewhere(name)) return name;
  const labels = host.toLowerCase().split(".");
  const label = labels.slice(0, -1).find((l) => !["www", "git", "gitlab", "ssh"].includes(l)) ?? labels[0] ?? "server";
  name = `${name}-${label}`;
  let candidate = name;
  for (let n = 2; elsewhere(candidate); n++) candidate = `${name}-${n}`;
  return candidate;
}

export interface GitHubEmail { email: string; primary?: boolean; verified?: boolean }

const unique = (list: (string | null | undefined)[]) => {
  const seen = new Set<string>();
  return list.map((e) => (e ?? "").trim()).filter((e) => e.includes("@") && !seen.has(e.toLowerCase()) && !!seen.add(e.toLowerCase()));
};

/** Verified addresses with the primary first; with the email kept private, GitHub's noreply address is offered too */
export function gitHubEmails(listed: GitHubEmail[] | null, publicEmail: string | null, userID: number, login: string, noreply: boolean): string[] {
  const verified = (listed ?? []).filter((e) => e.verified !== false).sort((a, b) => (a.primary ? 0 : 1) - (b.primary ? 0 : 1)).map((e) => e.email);
  return unique([publicEmail, ...verified, ...(noreply && !publicEmail ? [`${userID}+${login}@users.noreply.github.com`] : [])]);
}

/** The commit email first, then the account's and the public one */
export function gitLabEmails(commit: string | null, email: string | null, publicEmail: string | null): string[] {
  return unique([commit, email, publicEmail]);
}

const trimSlash = (p: string) => (p.length > 1 && !/^[A-Za-z]:[\\/]$/.test(p) ? p.replace(/[\\/]+$/, "") : p);
const parentOf = (p: string) => {
  const path = trimSlash(p), cut = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
  if (cut < 0) return "";
  return cut === 0 ? path[0] : /^[A-Za-z]:$/.test(path.slice(0, cut)) ? path.slice(0, cut + 1) : path.slice(0, cut);
};

/**
 * The folder rule's default: the parent folder of an open repository whose remote is on this server, never the home
 * folder, the Desktop or a drive's root. Null when no such repository is open.
 */
export function defaultGitchFolder(repositories: { path: string; host: string | null }[], host: string, home: string): string | null {
  const same = (a: string, b: string) => trimSlash(a).replace(/\\/g, "/").toLowerCase() === trimSlash(b).replace(/\\/g, "/").toLowerCase();
  const sep = home.includes("\\") ? "\\" : "/";
  for (const repo of repositories) {
    if (repo.host?.toLowerCase() !== host.toLowerCase()) continue;
    const parent = parentOf(repo.path);
    if (!parent || /^([A-Za-z]:)?[\\/]?$/.test(parent) || same(parent, home) || same(parent, trimSlash(home) + sep + "Desktop")) continue;
    return parent;
  }
  return null;
}
