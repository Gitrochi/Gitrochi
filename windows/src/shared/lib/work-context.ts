export type WorkScope = "staged" | "worktree" | "commits";

/** A local selection snapshot; repository paths never enter its serialized payload. */
export interface WorkContext {
  schemaVersion: 1;
  repositoryID: string;
  head: string | null;
  revision: string | null;
  scope: WorkScope;
  selectedPaths: string[];
  selectedNodeIDs: string[];
  screenID: string;
  observedAt: string;
  fingerprint: string;
}
export interface WorkContextInput {
  repositoryPath: string;
  head: string | null;
  revision?: string | null;
  scope: WorkScope;
  selectedPaths?: readonly string[];
  selectedNodeIDs?: readonly string[];
  screenID: string;
  observedAt?: string;
}
export interface WorkGraphSnapshot {
  schemaVersion: 1;
  id: string;
  nodeIDs: string[];
  edges: { source: string; target: string }[];
}
export type WorkGraphAction = { kind: "nodes" | "path"; nodeIDs: string[] } | { kind: "clear" };
export interface WorkGraphActions { schemaVersion: 1; snapshotID: string; actions: WorkGraphAction[] }

/** FNV-1a over UTF-8, mirrored by WorkContext.swift and the graph reader. */
export function workFingerprint(value: string): string {
  let hash = 2166136261;
  for (const byte of new TextEncoder().encode(value)) hash = Math.imul(hash ^ byte, 16777619) >>> 0;
  return hash.toString(16).padStart(8, "0");
}
export function workContextPath(path: string): boolean {
  return !!path && path.length <= 500 && !/[\\:\0\r\n]/.test(path) && !path.startsWith("/") && !path.split("/").some((part) => !part || part === "." || part === "..")
    && !/(^|\/)(?:\.git|\.env(?:\..*)?|\.ssh|\.aws|\.npmrc|\.netrc|credentials?|secrets?)(?:\/|$)|\.(?:pem|key|p12|pfx|keystore)$|(^|\/)id_(?:rsa|ed25519|ecdsa)(?:\.|$)/i.test(path);
}
const sorted = (items: readonly string[]) => [...new Set(items)].sort();
export function createWorkContext(input: WorkContextInput): WorkContext {
  const repositoryID = "repo-" + workFingerprint(input.repositoryPath.replaceAll("\\", "/").replace(/\/$/, ""));
  const selectedPaths = sorted(input.selectedPaths ?? []).filter(workContextPath).slice(0, 100);
  const selectedNodeIDs = sorted(input.selectedNodeIDs ?? []).filter((id) => !!id && id.length <= 500 && !/[\0\r\n]/.test(id)).slice(0, 100);
  const screenID = input.screenID.slice(0, 100);
  const head = input.head;
  const revision = input.revision ?? null;
  const fingerprint = workFingerprint(["1", repositoryID, head ?? "", revision ?? "", input.scope, screenID, selectedPaths.join("\0"), selectedNodeIDs.join("\0")].join("\u001f"));
  return { schemaVersion: 1, repositoryID, head, revision, scope: input.scope, selectedPaths, selectedNodeIDs, screenID, observedAt: input.observedAt ?? new Date().toISOString(), fingerprint };
}
export function sameWorkContext(a: WorkContext, b: WorkContext): boolean { return a.fingerprint === b.fingerprint; }

/** Validate every action before any graph selection changes. Paths follow directed edges. */
export function validateWorkGraphActions(value: unknown, snapshot: WorkGraphSnapshot): WorkGraphActions | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const envelope = value as Record<string, unknown>;
  if (Object.keys(envelope).some((key) => !["schemaVersion", "snapshotID", "actions"].includes(key)) || envelope.schemaVersion !== 1 || envelope.snapshotID !== snapshot.id || !Array.isArray(envelope.actions) || envelope.actions.length > 12) return null;
  const known = new Set(snapshot.nodeIDs), edges = new Set(snapshot.edges.map((edge) => JSON.stringify([edge.source, edge.target])));
  const actions: WorkGraphAction[] = [];
  for (const value of envelope.actions) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const action = value as Record<string, unknown>;
    if (action.kind === "clear" && Object.keys(action).length === 1) { actions.push({ kind: "clear" }); continue; }
    if ((action.kind !== "nodes" && action.kind !== "path") || Object.keys(action).some((key) => !["kind", "nodeIDs"].includes(key)) || !Array.isArray(action.nodeIDs) || !action.nodeIDs.length || action.nodeIDs.length > 100 || !action.nodeIDs.every((id): id is string => typeof id === "string" && known.has(id))) return null;
    const nodeIDs = action.nodeIDs;
    if (new Set(nodeIDs).size !== nodeIDs.length || (action.kind === "path" && (nodeIDs.length < 2 || nodeIDs.slice(1).some((id, index) => !edges.has(JSON.stringify([nodeIDs[index], id])))))) return null;
    actions.push({ kind: action.kind, nodeIDs: [...nodeIDs] });
  }
  return { schemaVersion: 1, snapshotID: snapshot.id, actions };
}

/** A bounded graph payload from the repository reader. */
export function parseWorkGraphSnapshot(text: string): WorkGraphSnapshot | null {
  try {
    const value: unknown = JSON.parse(text);
    if (!value || typeof value !== "object") return null;
    const graph = value as WorkGraphSnapshot;
    if (graph.schemaVersion !== 1 || typeof graph.id !== "string" || !graph.id || !Array.isArray(graph.nodeIDs) || graph.nodeIDs.length > 1000 || !graph.nodeIDs.every((id) => typeof id === "string" && id.length <= 500) || new Set(graph.nodeIDs).size !== graph.nodeIDs.length || !Array.isArray(graph.edges) || graph.edges.length > 4000) return null;
    const nodes = new Set(graph.nodeIDs);
    if (!graph.edges.every((edge) => edge && nodes.has(edge.source) && nodes.has(edge.target))) return null;
    return { schemaVersion: 1, id: graph.id, nodeIDs: [...graph.nodeIDs], edges: graph.edges.map(({ source, target }) => ({ source, target })) };
  } catch { return null; }
}
