import { CircleCheck, CircleDot } from "@/shared/icons";
import { CircleAlert, File } from "@/shared/icons";
import type { ReactNode } from "react";
import { fileName } from "@/entities/git";
import type { PullRequestReview, ReviewComment } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { listWhen, longDate } from "@/shared/lib";
import { Avatar, Markdown, StatusPill } from "@/shared/ui";
import { ReviewThreadActions } from "./ReviewPanels";

type MarkdownLinks = Omit<Parameters<typeof Markdown>[0], "text">;

/** A comment on a file opens a thread; its replies join it wherever the server lists them */
function activityItems(comments: ReviewComment[]): ReviewComment[][] {
  const items: ReviewComment[][] = [], threads = new Map<string, ReviewComment[]>();
  for (const comment of comments) {
    const thread = comment.kind === "comment" && comment.path && comment.threadID ? threads.get(comment.threadID) : undefined;
    if (thread) { thread.push(comment); continue; }
    const item = [comment];
    if (comment.kind === "comment" && comment.path && comment.threadID) threads.set(comment.threadID, item);
    items.push(item);
  }
  return items;
}

/**
 * The request's activity in the server's order: reviews and system events as one line, comments with their author,
 * comments on a file as a thread card. macOS: RequestActivity.swift.
 */
export function RequestActivity({ store, review, author, onOpenFile, ...markdown }: { store: RepoStore; review: PullRequestReview; /** the request's author, who gets the Author pill */ author: string; onOpenFile: (path: string) => void } & MarkdownLinks) {
  const when = (comment: ReviewComment) => comment.date != null && <time className="pr-cap" dateTime={new Date(comment.date * 1000).toISOString()} title={longDate(comment.date)}>{listWhen(comment.date)}</time>;
  const article = (comment: ReviewComment) => <article className="pr-comment" key={comment.id}>
    <span aria-hidden="true"><Avatar name={comment.author} email={comment.author} size={24}/></span>
    <div className="pr-comment-body">
      <header><strong>@{comment.author}</strong>{when(comment)}{comment.author === author && <StatusPill tone="neutral">{t("Author")}</StatusPill>}</header>
      {comment.body && <Markdown text={comment.body} {...markdown}/>}
    </div>
  </article>;
  // "@name approved these changes", with the name in semibold wherever the translation puts it
  const sentence = (key: string, name: string): ReactNode => {
    const [before, after = ""] = t(key, "\u0000").split("\u0000");
    return <span>{before}<strong>@{name}</strong>{after}</span>;
  };
  return <section className="request-activity" aria-label={t("Activity")}>
    {!review.comments.length && <p className="pr-cap">{t("No comments yet.")}</p>}
    <ol className="request-timeline">{activityItems(review.comments).map((item) => {
      const first = item[0];
      if (first.kind === "system") return <li key={first.id} className="request-event event-system">
        <div className="pr-event-line"><CircleDot size={16} aria-hidden="true"/><span><strong>@{first.author}</strong> {first.body}</span>{when(first)}</div>
      </li>;
      if (first.kind === "approved" || first.kind === "changesRequested") return <li key={first.id} className={`request-event event-${first.kind}`}>
        <div className="pr-event-line status-tone" data-tone={first.kind === "approved" ? "passed" : "waiting"}>
          {first.kind === "approved" ? <CircleCheck size={16} aria-hidden="true"/> : <CircleAlert size={16} aria-hidden="true"/>}
          {sentence(first.kind === "approved" ? "{0} approved these changes" : "{0} requested changes", first.author)}{when(first)}
        </div>
        {first.body && <div className="pr-event-note"><Markdown text={first.body} {...markdown}/></div>}
      </li>;
      if (first.path) {
        const path = first.path;
        return <li key={first.id} className="request-event event-thread">
          <section className="pr-thread" aria-label={path}>
            <header><File size={13} aria-hidden="true"/><button type="button" className="pr-link" title={path} onClick={() => onOpenFile(path)}>{fileName(path)}</button>{first.line != null && <span className="pr-cap">· {t("line {0}", first.line)}</span>}</header>
            <div className="pr-thread-body">{item.map(article)}<ReviewThreadActions store={store} number={review.number} comment={item.find((comment) => comment.resolvable) ?? first}/></div>
          </section>
        </li>;
      }
      return <li key={first.id} className="request-event event-comment">{article(first)}<div className="pr-comment-actions"><ReviewThreadActions store={store} number={review.number} comment={first}/></div></li>;
    })}</ol>
  </section>;
}
