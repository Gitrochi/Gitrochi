import { repositoryImageMime, type RepositoryBlob, type RepositoryTreeEntry } from "@/entities/git";

export const htmlPreviewCSP = "default-src 'none'; script-src 'none'; connect-src 'none'; img-src data:; style-src 'unsafe-inline' data:; font-src data:; base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'; media-src 'none'; manifest-src 'none'; worker-src 'none'; navigate-to 'none'";
export const previewAssetLimit = 20, previewAssetBytes = 8_000_000;
export const previewReferenceLimit = 60, previewEmbeddedCharacters = 12_000_000, previewDocumentLimit = 16_000_000;
export type PreviewBlobReader = (entry: RepositoryTreeEntry) => Promise<RepositoryBlob>;

/** Bound emitted content as well as unique reads, because one asset can be referenced repeatedly. */
export function createPreviewBudget() {
  let references = 0, characters = 0;
  const reserve = (size: number) => { if (size > previewEmbeddedCharacters - characters) return false; characters += size; return true; };
  return {
    reference: () => ++references <= previewReferenceLimit,
    embed: (value: string): string | null => reserve(value.length) ? value : null,
    style: (value: string): string | null => {
      let size = value.length;
      for (let i = 0; i < value.length; i++) if (value[i] === "<") size += 3;
      return reserve(size) ? value.replace(/</g, "\\3c ") : null;
    },
  };
}

/** Resolve URLs inside the immutable tree, never against the browser URL or working directory. */
export function previewAssetPath(file: string, value: string): string | null {
  const reference = value.trim();
  if (!reference || reference.startsWith("#") || /^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(reference) || /[\\\x00-\x1f\x7f]/.test(reference)) return null;
  let decoded: string;
  try { decoded = decodeURIComponent(reference.split(/[?#]/)[0]); } catch { return null; }
  if (!decoded || /[\\\x00-\x1f\x7f]/.test(decoded)) return null;
  const parts = reference.startsWith("/") ? [] : file.split("/").slice(0, -1);
  for (const part of decoded.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") { if (!parts.length) return null; parts.pop(); } else parts.push(part);
  }
  return parts.length ? parts.join("/") : null;
}

export function safePreviewImage(value: string): string | null {
  const match = value.match(/^data:(image\/(?:png|jpeg|gif|webp));base64,([a-z\d+/]*={0,2})$/i);
  if (!match || value.length > previewAssetBytes * 1.4) return null;
  try {
    const bytes = Uint8Array.from(atob(match[2].slice(0, 64)), (char) => char.charCodeAt(0));
    return repositoryImageMime(bytes) === match[1].toLowerCase() ? value : null;
  } catch { return null; }
}

/** The CSP and sandbox enforce isolation; URL rewriting only adds bounded local image/CSS support. */
export async function buildHTMLPreview(text: string, file: string, entries: RepositoryTreeEntry[], read: PreviewBlobReader): Promise<string> {
  const files = new Map(entries.filter((entry) => entry.kind === "file").map((entry) => [entry.path, entry]));
  const cache = new Map<string, Promise<RepositoryBlob | null>>();
  const budget = createPreviewBudget();
  let usedBytes = 0;
  const asset = (path: string): Promise<RepositoryBlob | null> => {
    const cached = cache.get(path); if (cached) return cached;
    const entry = files.get(path);
    if (!entry || !Number.isSafeInteger(entry.size) || entry.size < 0 || cache.size >= previewAssetLimit || entry.size > previewAssetBytes - usedBytes) return Promise.resolve(null);
    usedBytes += entry.size;
    const result = read(entry).catch(() => null); cache.set(path, result); return result;
  };
  const image = async (base: string, url: string): Promise<string | null> => {
    if (!budget.reference()) return null;
    const inline = safePreviewImage(url); if (inline) return budget.embed(inline);
    const path = previewAssetPath(base, url); if (!path) return null;
    const value = await asset(path), result = value?.image ? safePreviewImage(value.image) : null; return result ? budget.embed(result) : null;
  };
  const css = async (value: string, base: string, depth: number, visited: Set<string>): Promise<string> => {
    const imports = /@import\s+(?:url\(\s*(?:"([^"]*)"|'([^']*)'|([^\s)]*))\s*\)|"([^"]*)"|'([^']*)')\s*([^;]*);?/gi;
    let output = "", start = 0;
    for (const match of value.matchAll(imports)) {
      output += value.slice(start, match.index); start = match.index + match[0].length;
      if (!budget.reference()) continue;
      const path = previewAssetPath(base, match[1] ?? match[2] ?? match[3] ?? match[4] ?? match[5] ?? "");
      if (depth >= 2 || !path || visited.has(path) || !/\.css$/i.test(path)) continue;
      const loaded = await asset(path);
      if (loaded?.text != null) { const nested = await css(loaded.text, path, depth + 1, new Set([...visited, path])); output += budget.embed(match[6].trim() ? `@media ${match[6].trim()} {${nested}}` : nested) ?? ""; }
    }
    output += value.slice(start);
    const urls = /url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)/gi;
    let rewritten = ""; start = 0;
    for (const match of output.matchAll(urls)) {
      rewritten += output.slice(start, match.index); start = match.index + match[0].length;
      const resolved = await image(base, (match[1] ?? match[2] ?? match[3] ?? "").trim());
      rewritten += resolved ? `url("${resolved}")` : "none";
    }
    return rewritten + output.slice(start);
  };
  // Template content is inert while parsed, so remote URLs cannot load before sanitization.
  const template = document.createElement("template"); template.innerHTML = text;
  const fragment = template.content;
  const blockedTags = new Set(["SCRIPT", "IFRAME", "FRAME", "FRAMESET", "OBJECT", "EMBED", "APPLET", "BASE", "META", "SVG", "MATH", "TEMPLATE", "NOSCRIPT", "NOFRAMES", "NOEMBED", "XMP", "PLAINTEXT", "SOURCE", "TRACK", "AUDIO", "VIDEO", "PORTAL"]);
  const blockedAttributes = new Set(["src", "srcset", "imagesrcset", "href", "xlink:href", "action", "formaction", "target", "formtarget", "ping", "poster", "background", "data", "code", "codebase", "archive", "classid", "manifest", "profile", "longdesc", "usemap", "srcdoc", "autofocus", "http-equiv"]);
  for (const element of Array.from(fragment.querySelectorAll("*"))) {
    if (!fragment.contains(element)) continue;
    if (blockedTags.has(element.tagName) || element.namespaceURI !== "http://www.w3.org/1999/xhtml") { element.remove(); continue; }
    if (element.tagName === "LINK") {
      if (!budget.reference()) { element.remove(); continue; }
      const path = element.getAttribute("rel")?.toLowerCase().split(/\s+/).includes("stylesheet") ? previewAssetPath(file, element.getAttribute("href") ?? "") : null;
      const loaded = path && /\.css$/i.test(path) ? await asset(path) : null;
      if (loaded?.text != null && path) { const style = document.createElement("style"); style.textContent = budget.style(await css(loaded.text, path, 0, new Set([path]))) ?? ""; element.replaceWith(style); } else element.remove();
      continue;
    }
    const src = element.tagName === "IMG" ? element.getAttribute("src") : null;
    for (const attribute of Array.from(element.attributes)) if (attribute.name.toLowerCase().startsWith("on") || blockedAttributes.has(attribute.name.toLowerCase())) element.removeAttribute(attribute.name);
    if (element.tagName === "STYLE") element.textContent = budget.style(await css(element.textContent ?? "", file, 0, new Set())) ?? "";
    const inlineStyle = element.getAttribute("style");
    if (inlineStyle != null) element.setAttribute("style", await css(inlineStyle, file, 0, new Set()));
    if (src) { const resolved = await image(file, src); if (resolved) element.setAttribute("src", resolved); }
  }
  const output = document.implementation.createHTMLDocument("");
  const meta = output.createElement("meta"); meta.httpEquiv = "Content-Security-Policy"; meta.content = htmlPreviewCSP;
  const charset = output.createElement("meta"); charset.setAttribute("charset", "utf-8");
  const referrer = output.createElement("meta"); referrer.name = "referrer"; referrer.content = "no-referrer";
  output.head.replaceChildren(meta, charset, referrer); output.body.replaceChildren(fragment);
  const html = "<!doctype html>" + output.documentElement.outerHTML;
  if (html.length > previewDocumentLimit) throw new Error("This preview exceeds the 16 MB display limit.");
  return html;
}
