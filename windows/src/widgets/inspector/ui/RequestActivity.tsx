import { CheckCheck, CircleDot, MessageSquare, TriangleAlert } from "lucide-react";
import type { PullRequestReview } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { longDate, shortDate } from "@/shared/lib";
import { Avatar, Markdown } from "@/shared/ui";
import { ReviewThreadActions } from "./ReviewPanels";

/** Server activity in its original order. macOS: RequestActivity.swift. */
export function RequestActivity({ store, review, ...markdown }: { store: RepoStore; review: PullRequestReview } & Omit<Parameters<typeof Markdown>[0], "text">) {
  return <section className="request-activity" aria-label={t("Conversation")}>
    <h2>{t("Conversation {0}", review.comments.filter(c => c.kind !== "system").length)}</h2>
    {!review.comments.length && <p className="muted">{t("No comments yet.")}</p>}
    <ol className="request-timeline">{review.comments.map(c => <li key={c.id} className={`request-event event-${c.kind}`}>
      <span className="request-event-marker" aria-hidden="true">{c.kind === "system" ? <CircleDot size={15}/> : c.kind === "approved" ? <CheckCheck size={15}/> : c.kind === "changesRequested" ? <TriangleAlert size={15}/> : <MessageSquare size={15}/>}</span>
      <article className="request-event-content">
        <header><span aria-hidden="true"><Avatar name={c.author} email={c.author} size={24}/></span><strong>@{c.author}</strong>
          {c.kind === "approved" && <span className="request-approved">{t("✓ Approve")}</span>}
          {c.kind === "changesRequested" && <span className="request-changes">{t("Request changes")}</span>}
          {c.date != null && <time dateTime={new Date(c.date * 1000).toISOString()} title={longDate(c.date)}>{shortDate(c.date)}</time>}
        </header>
        {c.path && <code className="request-event-path">{c.path}{c.line != null ? `:${c.line}` : ""}</code>}
        {c.body && (c.kind === "system" ? <p className="request-system-body">{c.body}</p> : <Markdown text={c.body} {...markdown}/>)}
        {c.kind !== "system" && <ReviewThreadActions store={store} number={review.number} comment={c}/>}
      </article>
    </li>)}</ol>
  </section>;
}
