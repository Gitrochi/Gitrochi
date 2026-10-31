import { ArrowRight, ChevronDown, ChevronRight, Waves } from "lucide-react";
import { type CSSProperties, useEffect, useState } from "react";
import { compareVersions, type LedgerSession, type LedgerSessionDetail, type LedgerStore, type LedgerStreamCycle } from "@/entities/ledger";
import { t } from "@/shared/i18n";
import { longDate, shortDate, useObserve } from "@/shared/lib";
import { Empty } from "@/shared/ui";
import { ReportBody } from "./LedgerTimeline";
import { BaseLine, SessionId, VerdictBadge, When } from "./parts";

const cycleColor: Record<LedgerStreamCycle["state"], string> = { applied: "--green", active: "--accent", skipped: "--text-3" };
const cycleLabel: Record<LedgerStreamCycle["state"], string> = { applied: "Applied", active: "Active", skipped: "Skipped" };

/**
 * Implementation streams: long-running sessions that report in cycles instead of finishing. Each card lists its
 * cycles, newest first — read the baseline (sync), produce, apply — with the session that released that version and
 * its verdict, so a person sees what the decision side is waiting for. (macOS: Views/Ledger/LedgerStreams.swift)
 */
export function LedgerStreams({ store, onOpen }: { store: LedgerStore; onOpen: (sessionId: string) => void }) {
  useObserve(store);
  const state = store.state!;
  const streams = state.sessions.filter((s) => s.stream && (!store.project || s.project === store.project));
  if (!streams.length) return <Empty icon={<Waves size={30} strokeWidth={1.5} />} title={t("No implementation streams")} detail={t("A session whose kind is an implementation kind reports in cycles and shows up here.")} />;
  return (
    <div className="ledger-streams">
      {streams.map((s) => <StreamCard key={s.id} store={store} session={s} cycles={state.streams.filter((c) => c.sessionId === s.id).sort((a, b) => compareVersions(b.version, a.version))} onOpen={onOpen} />)}
    </div>
  );
}

function StreamCard({ store, session, cycles, onOpen }: { store: LedgerStore; session: LedgerSession; cycles: LedgerStreamCycle[]; onOpen: (id: string) => void }) {
  const [open, setOpen] = useState<string | null>(cycles[0]?.version ?? null);
  const [detail, setDetail] = useState<LedgerSessionDetail | null>(null);
  const rev = store.revision;
  useEffect(() => {
    let live = true;
    void store.readSession(session.id).then((d) => { if (live) setDetail(d); }, () => {});
    return () => { live = false; };
  }, [store, session.id, rev]);
  return (
    <article className="ledger-stream" aria-label={session.title} data-stream={session.id}>
      <header className="ledger-stream-head">
        <button type="button" className="link" onClick={() => onOpen(session.id)}><SessionId session={session} /></button>
        <h3>{session.title}</h3>
        <span className="hint">{session.stream?.line}</span>
        <VerdictBadge verdict={session.verdict} />
        <span className="spacer" />
        <BaseLine session={session} />
        <When at={session.lastAt} />
      </header>
      {!cycles.length && <div className="ledger-cycle-body hint">{t("No cycle yet: the stream has not read a baseline.")}</div>}
      {cycles.map((c) => {
        const expanded = open === c.version;
        const releaser = store.session(c.releasedBy);
        const events = detail ? c.eventIds.map((id) => detail.events.find((e) => e.id === id)).filter((e) => !!e) : [];
        const latest = [...events].reverse().find((e) => e.body) ?? null;
        return (
          <section key={c.version} className="ledger-cycle">
            <button type="button" className="ledger-cycle-head" aria-expanded={expanded} onClick={() => setOpen(expanded ? null : c.version)}>
              {expanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
              <span className="ledger-version">{c.version || "—"}</span>
              <span className="ledger-cycle-state" style={{ "--state": `var(${cycleColor[c.state]})` } as CSSProperties}>{t(cycleLabel[c.state])}</span>
              <span className="ledger-flow">
                {c.syncedAt ? <span data-tip={longDate(c.syncedAt / 1000)}>{t("Read {0}", shortDate(c.syncedAt / 1000))}</span> : <span>{t("Not read")}</span>}
                <ArrowRight size={12} />
                {c.appliedAt ? <span data-tip={longDate(c.appliedAt / 1000)}>{t("Applied {0}", shortDate(c.appliedAt / 1000))}</span> : <span>{t("Not applied")}</span>}
              </span>
              <span className="spacer" />
              {c.releasedBy && (
                <span className="ledger-flow" data-tip={t("The session that released this version")}>
                  {t("Released by")}
                  {releaser ? <SessionId session={releaser} /> : <span className="mono">{c.releasedBy}</span>}
                  {releaser && <VerdictBadge verdict={releaser.verdict} />}
                </span>
              )}
              <span className="hint">{t("{0} reports", c.eventIds.length)}</span>
            </button>
            {expanded && (
              <div className="ledger-cycle-body">
                {events.length ? (
                  <ul className="ledger-flow" style={{ flexDirection: "column", alignItems: "flex-start", margin: 0, paddingLeft: 16 }}>
                    {events.map((e) => <li key={e.id}><span className="mono">{e.type}</span> {e.summary} · {shortDate(e.ts / 1000)}</li>)}
                  </ul>
                ) : <span className="hint">{detail ? t("No reports in this cycle.") : t("Loading…")}</span>}
                {latest?.body && <ReportBody key={latest.id} text={latest.body} />}
                {releaser && releaser.id !== session.id && <button type="button" className="link" style={{ alignSelf: "flex-start" }} onClick={() => onOpen(releaser.id)}>{t("Open {0}", releaser.id)}</button>}
              </div>
            )}
          </section>
        );
      })}
    </article>
  );
}
