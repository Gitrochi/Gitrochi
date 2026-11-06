import type { RepoStore } from "@/entities/repo";

/** A person on a request; the signed-in account carries its photo (macOS: RequestAuthorAvatar) */
export const ownAvatarURL = (store: RepoStore, name: string) =>
  store.hostingAccount?.username.toLowerCase() === name.toLowerCase() ? store.hostingAccount?.avatarURL ?? undefined : undefined;
