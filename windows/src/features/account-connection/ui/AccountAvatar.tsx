import { avatars } from "@/entities/avatar";
import type { HostAccount } from "@/entities/git";
import { accountInitial } from "@/entities/hosting";
import { useObserve } from "@/shared/lib";
import { Avatar } from "@/shared/ui";

/**
 * One account, one picture: the toolbar button, its popover and Settings draw the same profile photo, and the
 * initial only for an account without one or while photos are turned off. (macOS: AccountAvatar)
 */
export function AccountAvatar({ account, size = 24 }: { account: HostAccount; size?: number }) {
  useObserve(avatars);
  const url = avatars.enabled ? account.avatarURL : null;
  // the key drops a failed image's state when the address changes
  return <Avatar key={url ?? "initial"} name={accountInitial(account.name, account.username)} email={account.username} url={url} size={size} />;
}
