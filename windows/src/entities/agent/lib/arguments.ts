import type { AgentKind } from "../model/agents";

/** The mode that skips every permission check. Never remembered; the start sheet asks for confirmation. */
export const bypassMode: Record<AgentKind, string> = { claude: "bypassPermissions", codex: "bypass", gemini: "yolo" };

export const skipsPermissions = (kind: AgentKind, mode: string | null | undefined) => !!mode && bypassMode[kind] === mode;

/** Command-line arguments for a session (macOS: AgentKind.arguments(hooks:task:mode:)) */
export function agentArguments(kind: AgentKind, hooks: string, task: string, mode: string | null): string[] {
  const prompt = task ? [task] : [];
  switch (kind) {
    case "claude":
      return ["--settings", hooks, ...(mode ? ["--permission-mode", mode] : []), ...prompt];
    case "codex":
      // --sandbox danger-full-access keeps the approval prompts; this flag drops both
      if (mode === bypassMode.codex) return ["--dangerously-bypass-approvals-and-sandbox", ...prompt];
      return [...(mode ? ["--sandbox", mode] : []), ...prompt];
    case "gemini":
      return [...(mode ? ["--approval-mode", mode] : []), ...(task ? ["-i", task] : [])];
  }
}
