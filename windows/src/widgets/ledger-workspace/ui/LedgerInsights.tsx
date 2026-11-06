import { BarChart3, Bot, Hourglass, MessageCircleQuestion, MessageSquareText } from "lucide-react";
import { Clock } from "@/shared/icons";
import { type ReactNode, useEffect, useState } from "react";
import { barShare, insightDuration, insightsEmpty, type LedgerInsights as Insights, type LedgerRange, ledgerRanges, ledgerRoles, type LedgerStore, type LedgerVerdict, verdictLook } from "@/entities/ledger";
import { language, t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Empty, Modal, Segmented, Spinner } from "@/shared/ui";
import { verdictIcon } from "./parts";
import "./ledger-insights.css";

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));
const rangeLabels: Record<LedgerRange, string> = { "7d": "7 days", "30d": "30 days", all: "All" };
const roleLabels = { decision: "Decision", implementation: "Implementation", research: "Research", document: "Document", other: "Other" } as const;
const kindLabels: Record<string, string> = { stop_question: "Asks before it stops", ask_user_question: "Asks you to choose", exit_plan_mode: "Plan to approve", permission: "Asks for permission" };
const verdictOrder: LedgerVerdict[] = ["needs_human", "confirm", "expirable", "pending_merge", "stale", "active", "shelved", "archived"];
type Tone = "waiting" | "failed" | "passed" | "info" | "neutral";

/** One number with its title and a line of context (macOS: LedgerStatTile) */
function Tile({ title, value, caption, icon, tone }: { title: string; value: string; caption: string; icon: ReactNode; tone?: Tone }) {
  return (
    <div className="ledger-insight-tile status-tone" data-tone={tone ?? "neutral"} data-tile={title}>
      <span className={`ledger-insight-tile-title${tone ? " toned" : ""}`}>{icon}{title}</span>
      <span className="ledger-insight-tile-value">{value}</span>
      <span className="hint">{caption}</span>
    </div>
  );
}

/** A labelled horizontal bar: its share of the largest value in the group (macOS: LedgerInsightBar) */
function Bar({ label, icon, value, max, tone }: { label: string; icon?: ReactNode; value: number; max: number; tone: Tone }) {
  const width = barShare(value, max);
  return (
    <div className="ledger-insight-bar status-tone" data-tone={tone} role="listitem" aria-label={`${label}: ${value}`}>
      <span className="ledger-insight-bar-label">{icon}{label}</span>
      <span className="ledger-insight-track"><span style={{ width: `${width}%` }} /></span>
      <span className="ledger-insight-count">{value}</span>
    </div>
  );
}

/**
 * Insights…: how long questions wait, how automatic answers fare, where sessions stand and how often agents report, over
 * a period, from the core's `insights` (counts and durations only). Stat tiles and plain bars, no chart library.
 * (macOS: Views/Ledger/LedgerInsightsSheet.swift)
 */
export function LedgerInsights({ store: ledger, onClose }: { store: LedgerStore; onClose: () => void }) {
  const store = useObserve(ledger);
  const [range, setRange] = useState<LedgerRange>(store.range === "7d" ? "7d" : store.range);
  const [project, setProject] = useState<string | null>(store.project);
  const [insights, setInsights] = useState<Insights | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let live = true;
    setLoading(true);
    store.insights(project, range).then(
      (next) => live && (setInsights(next), setError(null)),
      (e) => live && setError(message(e)),
    ).finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [store, project, range, attempt]);
  const d = (ms?: number) => insightDuration(ms, language);
  const body = () => {
    if (error) return <div className="ledger-insights-empty"><Empty title={t("The Ledger could not be read")} detail={error} /><Button onClick={() => setAttempt(attempt + 1)}>{t("Try again")}</Button></div>;
    if (!insights) return <div className="ledger-insights-empty"><Spinner size={16} /></div>;
    if (insightsEmpty(insights)) return <div className="ledger-insights-empty"><Empty icon={<BarChart3 size={24} />} title={t("Nothing to measure yet")} detail={t("Insights appear once agents report in this period. Choose a longer period or another project.")} /></div>;
    const { questions: q, autoAnswers: a, sessions: s } = insights;
    const most = Math.max(0, ...insights.reportsPerDay.map((x) => x.reports));
    const verdictMax = Math.max(0, ...Object.values(s.byVerdict)), roleMax = Math.max(0, ...Object.values(s.byRole));
    return (
      <div className="ledger-insights-report">
        <div className="ledger-insight-tiles">
          <Tile title={t("Question wait")} value={d(q.wait.medianMs)} caption={q.wait.count ? t("Median · p90 {0}", d(q.wait.p90Ms)) : t("None settled")} icon={<Hourglass size={12} />} />
          <Tile title={t("Open questions")} value={String(q.open.count)} caption={q.open.count ? t("Oldest {0}", d(q.open.maxMs)) : t("Nothing waiting")} icon={<MessageCircleQuestion size={12} />} tone={q.open.count ? "waiting" : undefined} />
          <Tile title={t("Automatic answers")} value={String(a.total)} caption={t("{0} reviewed · {1} corrected", a.reviewed, a.corrected)} icon={<Bot size={12} />} />
          <Tile title={t("Stale sessions")} value={String(s.stale)} caption={t("{0} never reported", s.staleUnreported)} icon={<Clock size={12} />} tone={s.stale ? "failed" : undefined} />
          <Tile title={t("Agent reports")} value={String(insights.reports)} caption={t("{0} sessions", s.total)} icon={<MessageSquareText size={12} />} />
        </div>
        <section className="ledger-insight-section">
          <h3>{t("Agent reports per day")}</h3>
          <div className="ledger-insight-chart status-tone" data-tone="info">
            <div className="ledger-insight-columns" role="list" aria-label={t("Agent reports per day")} data-days={insights.reportsPerDay.length}>
              {insights.reportsPerDay.map((day) => (
                <span key={day.day} role="listitem" data-tip={`${day.day} · ${day.reports}`} aria-label={`${day.day}: ${day.reports}`} className={day.reports ? "" : "zero"} style={{ height: day.reports ? `${barShare(day.reports, most)}%` : "2px" }} />
              ))}
            </div>
            <div className="ledger-insight-axis hint"><span>{insights.reportsPerDay[0]?.day}</span><span>{t("Most in a day: {0}", most)}</span><span>{insights.reportsPerDay[insights.reportsPerDay.length - 1]?.day}</span></div>
          </div>
        </section>
        <div className="ledger-insight-pair">
          <section className="ledger-insight-section">
            <h3>{t("Sessions by verdict")}</h3>
            <div role="list" data-insight="verdicts">
              {verdictOrder.map((v) => { const look = verdictLook(v), Icon = verdictIcon(v); return <Bar key={v} label={t(look.label)} icon={<Icon size={12} />} value={s.byVerdict[v] ?? 0} max={verdictMax} tone={look.tone} />; })}
            </div>
          </section>
          <section className="ledger-insight-section">
            <h3>{t("Sessions by role")}</h3>
            <div role="list" data-insight="roles">
              {ledgerRoles.map((r) => <Bar key={r} label={t(roleLabels[r])} value={s.byRole[r] ?? 0} max={roleMax} tone="info" />)}
            </div>
          </section>
        </div>
        <section className="ledger-insight-section">
          <h3>{t("Automatic answers by kind")}</h3>
          {a.byKind.length ? (
            <>
              <div role="list" data-insight="auto">
                {a.byKind.map((k) => (
                  <div key={k.kind} className="ledger-insight-bar" role="listitem" aria-label={`${t(kindLabels[k.kind] ?? k.kind)}: ${t("{0} reviewed · {1} corrected", k.reviewed, k.corrected)} · ${t("{0} not reviewed", k.unreviewed)}`}>
                    <span className="ledger-insight-bar-label">{t(kindLabels[k.kind] ?? k.kind)}</span>
                    <span className="ledger-insight-stack">
                      {([[k.reviewed - k.corrected, "passed"], [k.corrected, "waiting"], [k.unreviewed, "neutral"]] as const).map(([n, tone]) => n > 0 && <span key={tone} className="status-tone" data-tone={tone} style={{ width: `${(100 * n) / Math.max(1, k.total)}%` }} />)}
                    </span>
                    <span className="ledger-insight-count">{k.total}</span>
                  </div>
                ))}
              </div>
              <div className="ledger-insight-legend hint">
                {([["Reviewed", "passed"], ["Corrected", "waiting"], ["Not reviewed", "neutral"]] as const).map(([label, tone]) => <span key={tone}><i className="status-tone" data-tone={tone} />{t(label)}</span>)}
              </div>
            </>
          ) : <span className="hint">{t("No automatic answers in this period.")}</span>}
        </section>
        <section className="ledger-insight-section">
          <h3>{t("Questions in this period")}</h3>
          <div className="ledger-insight-facts">
            {([["Asked", q.asked], ["Answered", q.answered], ["Dismissed", q.dismissed], ["Closed by their agent", q.resolvedByAgent]] as const).map(([label, n]) => <span key={label}><strong>{n}</strong><span className="hint">{t(label)}</span></span>)}
          </div>
        </section>
      </div>
    );
  };
  return (
    <Modal title={<span className="ledger-insights-title">{t("Insights")}{loading && <Spinner size={12} />}</span>} width={780} onClose={onClose} footer={<Button onClick={onClose}>{t("Close")}</Button>}>
      <div className="ledger-insights" data-ledger-insights>
        <div className="ledger-insights-controls">
          <select className="select" aria-label={t("Project")} value={project ?? ""} onChange={(e) => setProject(e.target.value || null)}>
            <option value="">{t("All projects")}</option>
            {(store.state?.projects ?? []).map((p) => <option key={p.key} value={p.key}>{p.name}</option>)}
          </select>
          <span className="spacer" />
          <Segmented value={range} onChange={setRange} options={ledgerRanges.map((r) => ({ value: r, label: t(rangeLabels[r]) }))} />
        </div>
        {body()}
      </div>
    </Modal>
  );
}
