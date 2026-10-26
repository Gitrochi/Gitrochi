import { useEffect, useRef, useState } from "react";
import { accountApiBase, accountHost } from "@/entities/git";
import {
  accounts,
  accountWorkPage,
  markAccountWorkRead,
  type AccountWorkKind,
  type AccountWorkItem,
  type ReviewAccess,
} from "@/entities/hosting";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";
export function AccountWorkPanel({ inbox = false }: { inbox?: boolean }) {
  useObserve(accounts);
  const [accountID, setAccountID] = useState("");
  const [kind, setKind] = useState<AccountWorkKind>(inbox ? "inbox" : "mine");
  const [items, setItems] = useState<AccountWorkItem[]>([]),
    [page, setPage] = useState(0),
    [more, setMore] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const generation = useRef(0);
  const scope = useRef("");
  scope.current = JSON.stringify([accountID, kind, accounts.revision]);
  const selected = accounts.accounts.find((a) => a.id === accountID);
  const load = async (append = false) => {
    if (!selected) return;
    const id = ++generation.current,
      revision = accounts.revision,
      a = selected,
      scopeKey = scope.current;
    setBusy(true);
    setError("");
    try {
      const token = await accounts.token(a);
      const current = () =>
        generation.current === id &&
        accounts.revision === revision &&
        scope.current === scopeKey;
      if (!token || !current()) {
        if (current())
          throw new Error(t("No token. Reconnect the account in Settings."));
        return;
      }
      const c: ReviewAccess = {
        target: {
          provider: a.provider,
          remote: "",
          host: accountHost(a),
          path: "",
        },
        token,
        apiBase: accountApiBase(a),
        me: a.username,
        stillCurrent: current,
      };
      const n = append ? page + 1 : 1,
        result = await accountWorkPage(c, kind, n, a.id);
      if (current()) {
        setItems((old) =>
          append
            ? [
                ...old,
                ...result.items.filter((i) => !old.some((o) => o.id === i.id)),
              ]
            : result.items,
        );
        setPage(n);
        setMore(result.more);
      }
    } catch (e) {
      if (id === generation.current)
        setError(e instanceof Error ? e.message : String(e));
    } finally {
      if (id === generation.current) setBusy(false);
    }
  };
  useEffect(() => {
    generation.current++;
    setItems([]);
    setPage(0);
    setMore(false);
    setBusy(false);
    setError("");
    if (selected) void load();
    return () => {
      generation.current++;
    };
  }, [accountID, kind, accounts.revision]);
  const read = async (item: AccountWorkItem) => {
    if (!selected || busy) return;
    const id = ++generation.current,
      revision = accounts.revision,
      a = selected,
      scopeKey = scope.current;
    setBusy(true);
    setError("");
    try {
      const token = await accounts.token(a),
        current = () =>
          generation.current === id &&
          accounts.revision === revision &&
          scope.current === scopeKey;
      if (!token || !current()) return;
      await markAccountWorkRead(
        {
          target: {
            provider: a.provider,
            remote: "",
            host: accountHost(a),
            path: "",
          },
          token,
          apiBase: accountApiBase(a),
          me: a.username,
          stillCurrent: current,
        },
        item,
        a.id,
      );
      if (current())
        setItems((old) =>
          old.map((i) => (i.id === item.id ? { ...i, unread: false } : i)),
        );
    } catch (e) {
      if (id === generation.current)
        setError(e instanceof Error ? e.message : String(e));
    } finally {
      if (id === generation.current) setBusy(false);
    }
  };
  const changeAccount = (next: string) => {
    generation.current++;
    scope.current = "";
    setItems([]);
    setPage(0);
    setMore(false);
    setBusy(false);
    setError("");
    setAccountID(next);
  };
  const changeCategory = (next: AccountWorkKind) => {
    generation.current++;
    scope.current = "";
    setItems([]);
    setPage(0);
    setMore(false);
    setBusy(false);
    setError("");
    setKind(next);
  };
  const modes: [AccountWorkKind, string][] = [
    ["mine", "Authored requests"],
    ["assignedRequests", "Assigned requests"],
    ["review", "Review requested"],
    ["issues", "Assigned issues"],
    ["myIssues", "Authored issues"],
  ];
  return (
    <div className="col" style={{ gap: 14 }}>
      <p className="muted">
        {t(
          "Account scope uses the explicitly selected server and account. Repository Git identity stays unchanged.",
        )}
      </p>
      <div className="row">
        <select
          aria-label={t("Account and server")}
          value={accountID}
          onChange={(e) => changeAccount(e.target.value)}
        >
          <option value="">{t("Choose an account and server")}</option>
          {accounts.accounts.map((a) => (
            <option key={a.id} value={a.id}>
              {accountHost(a)} · @{a.username}
            </option>
          ))}
        </select>
        <Button disabled={!selected || busy} onClick={() => void load()}>
          {t("Refresh")}
        </Button>
        {busy && <Spinner />}
      </div>
      {selected && (
        <p className="muted">
          {accountHost(selected)} · @{selected.username} ·{" "}
          {selected.provider === "gitlab"
            ? t(
                "GitLab inbox shows pending To-Dos. Review requests depend on server version and permissions.",
              )
            : t(
                "GitHub inbox shows notifications. My work searches open requests and issues across accessible repositories.",
              )}
        </p>
      )}
      {!inbox && (
        <div className="row" style={{ flexWrap: "wrap" }}>
          {modes.map(([id, label]) => (
            <Button
              key={id}
              kind={id === kind ? "primary" : undefined}
              disabled={busy}
              onClick={() => changeCategory(id)}
            >
              {t(label)}
            </Button>
          ))}
        </div>
      )}
      {!accounts.accounts.length && (
        <Button
          onClick={() =>
            window.dispatchEvent(
              new CustomEvent("gitrochi-open-settings", { detail: "accounts" }),
            )
          }
        >
          {t("Connect account…")}
        </Button>
      )}
      {!selected && (
        <p className="muted">
          {t("Select an account to load work across its repositories.")}
        </p>
      )}
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
      {items.map((item) => (
        <div className="workspace-list-row" key={item.id}>
          <div>
            <strong>
              {item.unread ? "● " : ""}
              {item.number ? `#${item.number} ` : ""}
              {item.title}
            </strong>
            <p className="muted">
              {item.host}/{item.repository} · {item.state}
              {item.author ? ` · @${item.author}` : ""}
            </p>
          </div>
          <div className="row">
            {item.unread && item.readID && (
              <Button disabled={busy} onClick={() => void read(item)}>
                {t("Mark as read")}
              </Button>
            )}
            <Button onClick={() => void ipc.openUrl(item.url)}>
              {t("Open details in browser")}
            </Button>
          </div>
        </div>
      ))}
      {selected && page > 0 && !items.length && !busy && (
        <p className="muted">{t("No items in this page.")}</p>
      )}
      {more && (
        <Button disabled={busy} onClick={() => void load(true)}>
          {t("Load more")}
        </Button>
      )}
    </div>
  );
}
