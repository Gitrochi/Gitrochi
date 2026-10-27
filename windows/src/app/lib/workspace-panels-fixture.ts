/** Recognize only the personal-project catalog read used by the Home fixture. */
export function workspaceFixtureProjectQuery(method: string, url: string, body?: string): { owner: string } | null {
  const endpoint = new URL(url);
  if (method !== "POST" || endpoint.origin !== "https://api.github.com" || endpoint.pathname !== "/graphql") return null;
  try {
    const payload = JSON.parse(body ?? "{}") as { query?: unknown; variables?: { owner?: unknown } };
    if (typeof payload.query !== "string" || !/^\s*query\s*\(/.test(payload.query) || /\bmutation\b/.test(payload.query) || !payload.query.includes("user(login:$owner){projectsV2(") || typeof payload.variables?.owner !== "string") return null;
    return { owner: payload.variables.owner };
  } catch { return null; }
}
