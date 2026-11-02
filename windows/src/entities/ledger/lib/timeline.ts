import type { LedgerEvent } from "../model/types";

/** Passive observations remain available without burying reports and decisions. (macOS: LedgerTimeline) */
export function timelineEvents(events: readonly LedgerEvent[], showActivity = false, focus: number | null = null) {
  const list = events
    .filter((event) => showActivity || event.id === focus || !(event.actor === "hook" || (event.actor === "agent" && event.type === "heartbeat")))
    .sort((a, b) => b.ts - a.ts || b.id - a.id);
  return { events: list, hiddenActivity: events.length - list.length };
}
