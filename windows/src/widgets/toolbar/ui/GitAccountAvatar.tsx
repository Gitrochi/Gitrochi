import { useEffect, useState } from "react";
import { accountHost } from "@/entities/git";
import { gitAccountAvatarURL, gitAccountHost, gitAccountKey, type GitchAccount } from "@/entities/gitch";
import { accounts } from "@/entities/hosting";
import { avatars } from "@/entities/avatar";
import { ipc } from "@/shared/api";
import { useObserve } from "@/shared/lib";
import { Avatar } from "@/shared/ui";

/** Reuse connected profiles before public hosting profiles (macOS: GitAccountAvatar). */
export function GitAccountAvatar({ account }: { account: GitchAccount }) {
  useObserve(accounts); useObserve(avatars);
  const [remoteURL, setRemoteURL] = useState<string | null>(null);
  const connected = accounts.accounts.find((value) => gitAccountKey(accountHost(value), value.username) === gitAccountKey(account.hosts, account.id));
  const knownURL = connected?.avatarURL ?? gitAccountAvatarURL(account.hosts, account.id);
  useEffect(() => {
    let current = true;
    setRemoteURL(null);
    if (avatars.enabled && !knownURL) void (async () => {
      try {
        const server = new URL(`https://${gitAccountHost(account.hosts)}`);
        const response = await ipc.http("GET", new URL(`/api/v4/users?username=${encodeURIComponent(account.id)}`, server).href, {}, undefined, 8000);
        if (response.status !== 200 || !current) return;
        const values: unknown = JSON.parse(response.body);
        if (!Array.isArray(values)) return;
        const profile = values.find((value) => value?.username?.toLowerCase() === account.id.toLowerCase());
        if (typeof profile?.avatar_url !== "string") return;
        const image = new URL(profile.avatar_url, server);
        if (["http:", "https:"].includes(image.protocol) && current) setRemoteURL(image.href);
      } catch { /* Initials remain available when the server requires a connection. */ }
    })();
    return () => { current = false; };
  }, [account.id, account.hosts, knownURL, avatars.enabled]);
  const url = avatars.enabled ? knownURL ?? remoteURL : null;
  return <Avatar key={url ?? "initials"} name={connected?.name ?? account.id} email={account.id} url={url} size={28} />;
}
