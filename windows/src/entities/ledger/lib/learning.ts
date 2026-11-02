/** Local learning progress contains no practice answer text or Ledger session IDs. */
export interface LedgerLearningProgress {
  version: 1;
  step: number;
  completed: boolean;
  answerSent: boolean;
  deliveryState: "saved" | "delivered" | "confirmed" | "archived";
}

export const LEDGER_LEARNING_SETTING = "ledgerLearning";
export const ledgerLearningSteps = ["concepts", "views", "answer", "delivery", "connect"] as const;
export type LedgerLearningStep = (typeof ledgerLearningSteps)[number];

export const ledgerLearningTitles = ["Sessions and baselines", "Choose a view", "Try answering a question", "Follow an answer to completion", "Connect your agent"] as const;

export const ledgerLearningTopics = [
  { id: "setup", title: "Setup", body: "Use Connect agents to copy setup instructions for Claude Code and Codex. Start a new conversation after setup, then ask the agent for a start report with its session ID.", terms: "Claude Codex MCP connection hooks ChatGPT" },
  { id: "concepts", title: "Sessions and baselines", body: "A session is one unit of agent work. Its baseline is the version it started from. Later reports record progress, decisions and outcomes.", terms: "session baseline report version" },
  { id: "views", title: "Choose a view", body: "Inbox holds questions and decisions that need you. Board lists sessions, Graph shows their history, and Streams follows ongoing implementation.", terms: "Inbox Board Graph Streams" },
  { id: "answers", title: "Answer questions", body: "Choose an option, or focus the empty answer and press Tab to fill an explicit suggestion. Edit the draft, then send it. Choosing or filling never sends an answer.", detail: "For multiple choices, select all that apply. You can edit the combined answer or write a different one.", terms: "Tab suggestion custom multiple choices multi select draft" },
  { id: "delivery", title: "Answer delivery", body: "Saving an answer and delivering it are separate. The agent receives a reported answer with its next report or read. Confirming accepts the outcome; cleaning up archives the conversation.", detail: "Use Copy answer to paste a saved answer into a conversation that cannot read this Ledger.", terms: "saved delivered queued copy clipboard ChatGPT" },
  { id: "cleanup", title: "Review and clean up", body: "Confirm a finished result after reviewing it. Clean up archives the conversation without stopping an agent or deleting a branch. A stale session needs review; use Still active when its work continues.", terms: "confirm archive stale review cleanup merged closed" },
  { id: "shortcuts", title: "Keyboard shortcuts", body: "In Inbox, use ↑/↓ to move, Return to open, A to answer, C to confirm and E to clean up. Tab fills an empty answer only when an explicit suggestion exists. Return adds a line; use the form's send button when ready.", terms: "keyboard keys shortcut navigation" },
  { id: "troubleshooting", title: "Troubleshooting", body: "If a session is missing, check the selected project and Unreported filter. If no reports appear, verify the agent connection and ask for a report. Held prompts must be answered in the agent's terminal.", terms: "missing empty connection error held terminal privacy" },
  { id: "privacy", title: "Privacy", body: "Practice uses local example data. Ledger stores reports and saved answers. The browser extension reads only the ChatGPT conversation you connect and optional drafts accepted with Tab. It does not read other tabs or desktop predictions.", terms: "privacy data clipboard settings automatic permission" },
] as const;

export const ledgerLearningConnectBody = "Connect Claude Code or Codex through Connect agents. For ChatGPT web, use the browser extension to sync completed choice questions. Activity tracking alone is not an agent report.";

/** Only valid versioned progress can resume the tutorial. (macOS: LedgerLearningProgress) */
export function readLedgerLearning(value: unknown): LedgerLearningProgress {
  const raw = value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
  const valid = raw.version === 1;
  const answerSent = valid && raw.answerSent === true;
  const states = ["saved", "delivered", "confirmed", "archived"] as const;
  const deliveryState = answerSent && states.some((state) => state === raw.deliveryState) ? raw.deliveryState as LedgerLearningProgress["deliveryState"] : "saved";
  const requested = valid && typeof raw.step === "number" && Number.isInteger(raw.step) ? Math.max(0, Math.min(4, raw.step)) : 0;
  const step = Math.min(requested, answerSent ? deliveryState === "archived" ? 4 : 3 : 2);
  return { version: 1, step, completed: valid && raw.completed === true && answerSent && deliveryState === "archived", answerSent, deliveryState };
}

/** Answering and finishing the practice review are the tutorial's only action gates. */
export function canAdvanceLedgerLearning(progress: LedgerLearningProgress): boolean {
  return progress.step === 2 ? progress.answerSent : progress.step === 3 ? progress.answerSent && progress.deliveryState === "archived" : true;
}

/** Practice delivery advances one visible operation at a time. */
export function advanceLearningDelivery(state: LedgerLearningProgress["deliveryState"]): LedgerLearningProgress["deliveryState"] {
  return state === "saved" ? "delivered" : state === "delivered" ? "confirmed" : "archived";
}

/** All words may match translated content or topic terms; the user's search is never a regular expression. */
export function searchLedgerGuide(query: string, translate: (key: string) => string = (key) => key) {
  const words = query.normalize("NFC").toLocaleLowerCase().split(/\s+/).filter(Boolean);
  return ledgerLearningTopics.filter((topic) => {
    const detail = "detail" in topic ? translate(topic.detail) : "";
    const haystack = `${translate(topic.title)} ${translate(topic.body)} ${detail} ${topic.terms}`.normalize("NFC").toLocaleLowerCase();
    return words.every((word) => haystack.includes(word));
  });
}
