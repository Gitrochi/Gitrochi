import type { LedgerReleaseNotes } from "../model/types";

type Translate = (text: string, ...values: (string | number)[]) => string;

/** The line above the draft: how many sessions went into the version (macOS: LedgerReleaseNotesSheet.summary) */
export function releaseNotesSummary(notes: LedgerReleaseNotes, t: Translate): string {
  const sessions = notes.groups.reduce((sum, group) => sum + group.sessions.length, 0);
  return sessions ? t("Sessions merged into {0}: {1}", notes.version, sessions) : t("No sessions were merged into {0}.", notes.version);
}
