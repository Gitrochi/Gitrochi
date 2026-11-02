/** Account labels may include an SSH port description (macOS: GitAccountPresentation). */
export const gitAccountHost = (label: string) => label.trim().split(/[\s,(]/, 1)[0].toLowerCase();
export const gitAccountKey = (host: string, username: string) => `${gitAccountHost(host)}/${username.toLowerCase()}`;
export function gitAccountAvatarURL(host: string, username: string): string | null {
  return gitAccountHost(host) === "github.com" && /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/.test(username)
    ? `https://github.com/${username}.png?size=64` : null;
}
