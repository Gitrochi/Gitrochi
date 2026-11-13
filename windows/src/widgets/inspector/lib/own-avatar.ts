import { gitAccountAvatarURL } from "@/entities/gitch";
import { avatarURL } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";

/** Prefer the response's profile, then the connected account and public GitHub login (macOS: RequestAuthorAvatar). */
export function ownAvatarURL(store: RepoStore, name: string, url?: string | null): string | null {
  const target = store.target;
  if (!target) return null;
  const context = { target, apiBase: `https://${target.host}` };
  const own = store.hostingAccount?.username.toLowerCase() === name.toLowerCase() ? store.hostingAccount.avatarURL : null;
  return avatarURL(context, url) ?? avatarURL(context, own)
    ?? (target.provider === "github" ? gitAccountAvatarURL(target.host, name) : null);
}
