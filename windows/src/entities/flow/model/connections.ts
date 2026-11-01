import { t } from "@/shared/i18n";
import { flowEngine } from "./engine";

export interface FlowConnection {
  name: string;
  kind: "github" | "gitlab" | "jenkins" | "http" | "webhook";
  url: string;
  user: string | null;
  project: string | null;
  secret: string;
  allow: string[];
}
export interface FlowRemoteBrowse {
  schemaVersion: 1;
  provider: "jenkins";
  connection: string;
  jobs: { name: string; path: string; url: string; folder: boolean }[];
  runs: { id: string; title: string; status: string; url: string; startedAt: number; durationMs: number }[];
  log: string | null;
  truncated: boolean;
}

export async function listFlowConnections(repo: string): Promise<FlowConnection[]> {
  return (await flowEngine.json<{ connections: FlowConnection[] }>(["connect", "list"], repo)).connections;
}

export function connectionProblem(value: FlowConnection): string | null {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/.test(value.name)) return t("Use letters, numbers, dots, dashes or underscores for the connection name.");
  try {
    const url = new URL(value.url || (value.kind === "github" ? "https://api.github.com" : ""));
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) return t("Enter an HTTP or HTTPS server address without credentials or query parameters.");
  } catch { return t("Enter an HTTP or HTTPS server address without credentials or query parameters."); }
  if (!/^(keystore|env:[A-Za-z_][A-Za-z0-9_]*|app:[A-Za-z0-9._-]+|gh:[A-Za-z0-9-]+)$/.test(value.secret)) return t("Choose a saved credential reference, such as env:CI_TOKEN. Do not enter a token here.");
  return null;
}

export async function saveFlowConnection(repo: string, value: FlowConnection): Promise<void> {
  const problem = connectionProblem(value);
  if (problem) throw new Error(problem);
  await flowEngine.json(["connect", "add", value.kind, "--name", value.name, "--url", value.url, "--secret-from", value.secret,
    ...(value.user ? ["--user", value.user] : []), ...(value.project ? ["--project", value.project] : []), "--allow", value.allow.join(",")], repo);
}

export function testFlowConnection(repo: string, name: string) {
  return flowEngine.json<{ ok: boolean; message: string; action?: string }>(["connect", "test", name], repo, [0, 1], 20_000);
}

export function browseFlowConnection(repo: string, name: string, job = "", run?: string) {
  return flowEngine.json<FlowRemoteBrowse>(["ci", "browse", ...(job ? [job] : []), ...(run ? [run] : []), "--connection", name], repo, [0], 25_000);
}
