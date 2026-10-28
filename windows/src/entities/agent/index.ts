// entities/agent 의 공개 API — 다른 조각은 이 파일로만 가져온다
export { type AgentHost, type AgentKind, agentKind, agentKinds, agents, type AgentSession, type AgentStatus, agentStatusTitle, isActiveStatus, type TerminalAgent } from "./model/agents";
export { skipsPermissions } from "./lib/arguments";
export { agentHost, appDisplayName, containingRoot, type ExternalAgent, externalAgentKind, relativeFolder, resolveExternalAgents, terminalShell } from "./lib/external-agents";
