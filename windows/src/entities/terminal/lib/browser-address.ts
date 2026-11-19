/**
 * What a browser tab's address bar does with typed text: an address, or a search.
 * macOS: BrowserAddress in Services/BrowserSession.swift
 */

/** Where the address bar sends a search, chosen in Settings › Tools; titles are product names (macOS: SearchEngine) */
export const searchEngines = [
  { id: "google", title: "Google", url: "https://www.google.com/search?q=" },
  { id: "duckduckgo", title: "DuckDuckGo", url: "https://duckduckgo.com/?q=" },
  { id: "bing", title: "Bing", url: "https://www.bing.com/search?q=" },
  { id: "naver", title: "Naver", url: "https://search.naver.com/search.naver?query=" },
] as const;

export const searchEngineKey = "browserSearchEngine";

/** The search address of an engine id; Google for an unknown one */
export const searchURL = (engine = "google") => (searchEngines.find((e) => e.id === engine) ?? searchEngines[0]).url;

function hostPart(value: string): string {
  const end = value.search(/[/?#]/);
  const authority = end < 0 ? value : value.slice(0, end);
  if (authority.startsWith("[")) return authority.slice(0, authority.indexOf("]") + 1 || authority.length);
  return authority.split(":")[0];
}

/** Dev servers: plain http */
export function isLocalHost(value: string): boolean {
  const host = hostPart(value).toLowerCase();
  const parts = host.split(".");
  return (
    host === "localhost" ||
    host.endsWith(".localhost") ||
    host === "0.0.0.0" ||
    host.startsWith("127.") ||
    host === "[::1]" ||
    (parts.length === 4 && parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255))
  );
}

/** localhost, an IP address, or a name with a dot, each with an optional port and path */
export function looksLikeHost(value: string): boolean {
  if (isLocalHost(value)) return true;
  const labels = hostPart(value).split(".");
  const last = labels[labels.length - 1] ?? "";
  return labels.length > 1 && labels.every((l) => l.length > 0) && (/^\p{L}+$/u.test(last) || /^\d+$/.test(last));
}

/** The address to open, or null for empty text */
export function resolveAddress(text: string, engine = "google"): string | null {
  const value = text.trim();
  if (!value) return null;
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(value)?.[1].toLowerCase();
  if (scheme === "about" || ((scheme === "http" || scheme === "https") && /^[a-z]+:\/\/[^/?#\s]+/i.test(value))) return value;
  if (!/\s/.test(value) && looksLikeHost(value)) return (isLocalHost(value) ? "http://" : "https://") + value;
  return searchURL(engine) + encodeURIComponent(value);
}
