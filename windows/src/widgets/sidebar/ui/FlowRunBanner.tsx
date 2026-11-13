import { ShieldAlert } from "lucide-react";
import { type FlowBanner, formatDuration } from "@/entities/flow";
import { Circle } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { NoticeBlock } from "@/shared/ui";
import { FlowStateIcon, stateTitle } from "./FlowState";

/**
 * The one strip above the graph (docs/design.md: white, 1 px border, status in the icon). It answers what a person
 * needs before touching anything: is it running, must the commands be reviewed, how did the latest run end, or
 * what will Run flow do. (macOS: FlowRunBanner)
 */
export function FlowRunBanner({ banner, created = false, steps, onOpenRun, onReview }: {
  banner: FlowBanner;
  /** The flow was just created here: the review strip says so, because reviewing is the next step */
  created?: boolean;
  /** How many steps the flow has, for the progress line of a running flow */
  steps: { done: number; total: number };
  onOpenRun: (runId: string) => void;
  onReview: () => void;
}) {
  switch (banner.kind) {
    case "running":
      return (
        <NoticeBlock className="flow-banner" tone="waiting" icon={<FlowStateIcon state="RUNNING" size={14} />}
          title={banner.step ? t("Running {0}", banner.step) : t("Running")}
          caption={steps.total ? t("{0} of {1} steps done", steps.done, steps.total) : null}
          actions={[{ label: t("Open run…"), onClick: () => onOpenRun(banner.runId) }]} />
      );
    case "review":
      return (
        <NoticeBlock className="flow-banner" tone="waiting" icon={<ShieldAlert size={14} />}
          title={created ? t("Flow created. Review its commands, then run it.") : t("Review required")}
          caption={t("This flow file is new or changed. Review the commands before running it.")}
          actions={[{ label: t("Review commands…"), onClick: onReview }]} />
      );
    case "finished": {
      const title = banner.tone === "passed" ? t("Latest run passed")
        : banner.failedStep ? t("Latest run failed at {0}", banner.failedStep)
        : t("Latest run: {0}", stateTitle(banner.state));
      const caption = [
        banner.durationMs != null ? t("Took {0}", formatDuration(banner.durationMs)) : null,
        banner.skipped.length ? t("Skipped: {0}", banner.skipped.join(", ")) : null,
      ].filter(Boolean).join(" · ");
      return (
        <NoticeBlock className="flow-banner" tone={banner.tone} icon={<FlowStateIcon state={banner.state} size={14} />}
          title={title} caption={caption || null}
          actions={[{ label: t("Open run…"), onClick: () => onOpenRun(banner.runId) }]} />
      );
    }
    case "ready":
      return (
        <NoticeBlock className="flow-banner" tone="neutral" icon={<Circle size={14} />}
          title={t("Not run yet")}
          caption={t("Run flow starts each step on this computer once the steps it needs have passed.")} />
      );
  }
}
