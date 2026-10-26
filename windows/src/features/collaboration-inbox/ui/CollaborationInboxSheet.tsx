import { useEffect, useState } from "react";
import type { RepoStore } from "@/entities/repo";
import { useObserve } from "@/shared/lib";
import { t } from "@/shared/i18n";
import { Button, Modal, Spinner } from "@/shared/ui";
import "./collaboration-inbox.css";
/** 연결된 현재 저장소의 담당 이슈·리뷰 요청·멘션과 대화를 처리한다. */
export function CollaborationInboxSheet({
  store,
  close,
  embedded = false,
  initialKind,
}: {
  store: RepoStore;
  close: () => void;
  embedded?: boolean;
  initialKind?: "issue" | "review" | "mention";
}) {
  useObserve(store);
  const [draft, setDraft] = useState("");
  useEffect(() => {
    void store.loadInbox(initialKind);
  }, [store, store.path, store.hostingAccount?.id, initialKind]);
  useEffect(() => setDraft(""), [store.inboxDetail?.item.id]);
  const detail = store.inboxDetail,
    item = detail?.item,
    disabled = store.inboxBusy || store.inboxLoading;
  const content = (
    <div
      className="collaboration-inbox col"
      style={
        embedded ? { flex: 1, minHeight: 0, maxHeight: "none" } : undefined
      }
    >
      <div className="row">
        <strong>{t("Issues and mentions")}</strong>
        <span className="spacer" />
        {disabled && <Spinner size={14} />}
        <Button onClick={() => void store.loadInbox()} disabled={disabled}>
          {t("Refresh")}
        </Button>
      </div>
      <span className="muted">
        {store.target?.host}/{store.target?.path} · @
        {store.hostingAccount?.username}
      </span>
      <div className="row">
        {(["issue", "review", "mention"] as const).map((kind) => (
          <Button
            key={kind}
            kind={store.inboxKind === kind ? "primary" : undefined}
            disabled={disabled}
            onClick={() => void store.loadInbox(kind)}
          >
            {t(
              kind === "issue"
                ? "Assigned issues"
                : kind === "review"
                  ? "Review requested"
                  : "Mentions",
            )}
          </Button>
        ))}
      </div>
      {store.inboxError && (
        <div className="error-text selectable">{store.inboxError}</div>
      )}
      <div className="inbox-columns">
        <div className="col inbox-list">
          {store.inboxItems.map((i) => (
            <button
              key={i.id}
              className={`inbox-item ${item?.id === i.id ? "selected" : ""}`}
              onClick={() => void store.openInboxItem(i)}
            >
              <strong>
                {i.unread ? "● " : ""}#{i.number} {i.title}
              </strong>
              <span className="muted">
                {i.author && `@${i.author} · `}
                {i.state}
              </span>
            </button>
          ))}
          {!store.inboxItems.length && !store.inboxLoading && (
            <span className="muted">{t("No items in this page.")}</span>
          )}
          {store.inboxMore && (
            <Button
              disabled={disabled}
              onClick={() => void store.loadInbox(store.inboxKind, true)}
            >
              {t("Load more")}
            </Button>
          )}
        </div>
        <div className="col inbox-detail">
          {detail && item ? (
            <>
              <strong>
                #{item.number} {item.title}
              </strong>
              <div className="row">
                <span className="muted">{item.state}</span>
                <Button size="small" onClick={() => store.openUrl(item.url)}>
                  {t("Browser")}
                </Button>
                {item.unread && item.readID && (
                  <Button
                    size="small"
                    disabled={disabled}
                    onClick={() => void store.inboxAction(item, "read")}
                  >
                    {t("Mark as read")}
                  </Button>
                )}
                {item.kind === "issue" && (
                  <Button
                    size="small"
                    disabled={disabled}
                    onClick={() => store.confirmInboxState(item)}
                  >
                    {["open", "opened"].includes(item.state)
                      ? t("Close issue…")
                      : t("Reopen…")}
                  </Button>
                )}
              </div>
              <p className="selectable">{item.body || t("No description")}</p>
              {detail.comments.map((c) => (
                <div className="inbox-comment" key={c.id}>
                  <strong>@{c.author}</strong>
                  <p className="selectable">{c.body}</p>
                </div>
              ))}
              {detail.more && (
                <Button
                  disabled={disabled}
                  onClick={() => void store.openInboxItem(item, true)}
                >
                  {t("Load more comments")}
                </Button>
              )}
              <textarea
                aria-label={t("Comment")}
                rows={3}
                value={draft}
                disabled={disabled}
                onChange={(e) => setDraft(e.target.value)}
              />
              <Button
                kind="primary"
                disabled={disabled || !draft.trim()}
                onClick={() => {
                  const sent = draft;
                  void store.inboxAction(item, "comment", sent).then((ok) => {
                    if (ok && store.inboxDetail?.item.id === item.id)
                      setDraft((s) => (s === sent ? "" : s));
                  });
                }}
              >
                {t("Comment")}
              </Button>
            </>
          ) : (
            <span className="muted">
              {t("Select an item to read its conversation.")}
            </span>
          )}
        </div>
      </div>
      <div className="row">
        <span className="muted">
          {t("Only the selected repository and connected account are queried.")}
        </span>
        <span className="spacer" />
        {!embedded && (
          <Button disabled={store.inboxBusy} onClick={close}>
            {t("Done")}
          </Button>
        )}
      </div>
    </div>
  );
  return embedded ? (
    content
  ) : (
    <Modal
      width={1000}
      onClose={() => {
        if (!store.inboxBusy) close();
      }}
    >
      {content}
    </Modal>
  );
}
