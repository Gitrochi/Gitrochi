/** Keeps generated graph documents offline and treats assistant actions as data. */
export function structureGraphDocument(html: string, actionsJSON?: string): string {
  if (!html.includes('id="graph-data"') || !html.includes("<head>") || !html.includes("</body>") || html.length > 100_000_000) throw new Error("The generated graph document is invalid.");
  if (actionsJSON && actionsJSON.length > 65_536) throw new Error("The graph action request is too large.");
  const actions: unknown = actionsJSON ? JSON.parse(actionsJSON) : null;
  const encoded = JSON.stringify(actions).replace(/[<>&\u2028\u2029]/g, c => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);
  const policy = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; base-uri 'none'; form-action 'none'">`;
  const bridge = `<script>document.addEventListener("click",function(event){const link=event.target.closest&&event.target.closest("a[href]");if(link&&link.href.startsWith("gitrochi:")){event.preventDefault();parent.postMessage({type:"gitrochi-graph-open",url:link.href},"*");}});</script>`;
  return html.replace("<head>", `<head>${policy}<script id="graph-actions" type="application/json">${encoded}</script>`).replace("</body>", `${bridge}</body>`);
}

/** Only repository-contained file/commit navigation can leave the sandbox. */
export function graphWorkspaceLink(value: unknown, repository: string): string | null {
  if (typeof value !== "string" || value.length > 8192) return null;
  try {
    const url = new URL(value);
    const normalize = (path: string) => path.replace(/\\/g, "/").replace(/\/+$/, "");
    if (url.protocol !== "gitrochi:" || url.hostname !== "open" || !["", "/"].includes(url.pathname) || url.username || url.password || url.hash) return null;
    if (normalize(url.searchParams.get("repo") ?? "") !== normalize(repository)) return null;
    if ([...url.searchParams.keys()].some(key => !["repo", "view", "file", "line", "commit"].includes(key))) return null;
    if ([...url.searchParams.keys()].some(key => url.searchParams.getAll(key).length !== 1)) return null;
    if (url.searchParams.get("view") !== "graph") return null;
    const file = url.searchParams.get("file");
    if (file !== null && (!file || /[\\:\u0000-\u001f]/.test(file) || file.startsWith("/") || file.split("/").some(part => !part || part === ".." || part === "."))) return null;
    const line = url.searchParams.get("line"), commit = url.searchParams.get("commit");
    if (line !== null && !/^[1-9][0-9]{0,7}$/.test(line)) return null;
    if (commit !== null && !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(commit)) return null;
    return url.href;
  } catch { return null; }
}
