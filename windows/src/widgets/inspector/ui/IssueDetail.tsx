import { CircleCheck, CircleDot, ExternalLink, Pencil, RefreshCw, RotateCcw } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { markdownLinks } from "@/entities/git";
import type { InboxDetail } from "@/entities/hosting";
import type { RepoStore } from "@/entities/repo";
import { keyLabel } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, IconButton, Markdown, Spinner } from "@/shared/ui";
import "./inspector.css";

/**
 * An issue on the Issues page, laid out like the pull request detail: title, details, the Markdown description,
 * the conversation and a reply box at the bottom. (macOS: IssueDetailView.swift)
 */
export function IssueDetail({ store, detail }: { store: RepoStore; detail: InboxDetail }) {
  useObserve(store);
  const item = detail.item;
  const [draft, setDraft] = useState("");
  useEffect(() => setDraft(""), [item.id]);
  const md = useMemo(() => markdownLinks(store.target), [store.target]);
  const open = ["open", "opened"].includes(item.state);
  const busy = store.inboxBusy || store.inboxLoading;
  const text = draft.trim();
  const send = () => {
    if (!text || busy) return;
    const sent = draft, id = item.id;
    void store.inboxAction(item, "comment", sent).then((ok) => {
      if (ok && store.inboxDetail?.item.id === id) setDraft((current) => (current === sent ? "" : current));
    });
  };
  return (
    <div className="col grow issue-detail" style={{ height: "100%" }}>
      <div className="panel-head">
        {open ? <CircleDot size={15} style={{ color: "var(--green)" }} /> : <CircleCheck size={15} className="muted" />}
        <span style={{ fontWeight: 600 }}>{t("Issue #{0}", item.number)}</span>
        <span className="spacer" />
        {store.inboxLoading && <Spinner size={12} />}
        <IconButton small icon={<RefreshCw size={12} />} tip={t("Refresh conversation")} aria-label={t("Refresh conversation")} onClick={() => void store.openInboxItem(item)} />
      </div>
      <div className="panel-scroll" key={item.id}>
        <div className="selectable" style={{ fontSize: 16, fontWeight: 600 }}>{item.title}</div>
        <div style={{ display: "grid", gridTemplateColumns: "auto 1fr", gap: "6px 10px" }}>
          <span className="muted">{t("Author")}</span>
          <span>@{item.author}</span>
          <span className="muted">{t("State")}</span>
          <span>{open ? t("Open") : t("Closed")}</span>
        </div>
        <div className="row" style={{ flexWrap: "wrap" }}>
          <Button disabled={busy} onClick={() => store.openSheet({ kind: "issueEditor", number: item.number, title: item.title, body: item.body })}>
            <Pencil size={14} /> {" "}{t("Edit issue")}</Button>
          <Button disabled={busy} onClick={() => store.confirmIssueState(item)}>
            {open ? <CircleCheck size={14} /> : <RotateCcw size={14} />} {" "}{open ? t("Close issue…") : t("Reopen…")}</Button>
          <Button onClick={() => store.openUrl(item.url)}>
            <ExternalLink size={14} /> {" "}{t("Browser")}</Button>
        </div>
        <div style={{ height: 1, background: "var(--border)" }} />
        {item.body.trim() ? <Markdown text={item.body} {...md} /> : <span className="muted">{t("No description")}</span>}
        {store.inboxError && <span className="error-text selectable" style={{ fontSize: 11.5, whiteSpace: "pre-wrap" }}>{store.inboxError}</span>}
        <div className="col" style={{ gap: 8 }}>
          <span style={{ fontWeight: 600 }}>{t("Conversation {0}", detail.comments.length)}</span>
          {detail.comments.map((c) => (
            <div key={c.id} className="review-comment">
              <span style={{ fontWeight: 600 }}>@{c.author}</span>
              {c.body && <Markdown text={c.body} {...md} />}
            </div>
          ))}
          {detail.more && <Button size="small" disabled={busy} onClick={() => void store.openInboxItem(item, true)}>{t("Load more comments")}</Button>}
        </div>
      </div>
      <div className="col" style={{ gap: 6, padding: 10, borderTop: "1px solid var(--border)" }}>
        <textarea
          className="textarea"
          style={{ height: 58 }}
          aria-label={t("Comment")}
          placeholder={t("Write a comment (Markdown)")}
          value={draft}
          disabled={store.inboxBusy}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); send(); } }}
        />
        <div className="row" style={{ gap: 6 }}>
          {store.inboxBusy && <Spinner size={12} />}
          <span className="spacer" />
          <Button size="small" kind="primary" disabled={!text || busy} tip={keyLabel(t("Comment (Ctrl+Enter)"))} onClick={send}>{t("Comment")}</Button>
        </div>
      </div>
    </div>
  );
}
