import { useState } from "react";
import { avatars } from "@/entities/avatar";
import type { HostAccount } from "@/entities/git";
import { accountInitial } from "@/entities/hosting";
import { useObserve } from "@/shared/lib";
import "./account-avatar.css";

/**
 * A profile photo, or the board's tinted initial for an account without one, while photos are turned off, or when
 * the picture can't be loaded. The letter is 11 px, 13 px from 32 px up. (macOS: AccountAvatar)
 */
export function AccountPhoto({ name, username, url, size = 24 }: { name?: string | null; username: string; url?: string | null; size?: number }) {
  useObserve(avatars);
  const [broken, setBroken] = useState<string | null>(null);
  const source = avatars.enabled && url && broken !== url ? url : null;
  return (
    <span className="avatar account-avatar" style={{ width: size, height: size, fontSize: size >= 32 ? 13 : 11 }}>
      {source ? <img src={source} width={size} height={size} onError={() => setBroken(source)} alt="" /> : accountInitial(name, username)}
    </span>
  );
}

/** One account, one picture: the toolbar button, its popover and Settings draw the same one */
export function AccountAvatar({ account, size = 24 }: { account: HostAccount; size?: number }) {
  return <AccountPhoto name={account.name} username={account.username} url={account.avatarURL} size={size} />;
}
