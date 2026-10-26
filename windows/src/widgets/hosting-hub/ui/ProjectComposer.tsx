import { useEffect, useRef, useState } from "react";
import { Circle, FilePlus2, Link, Plus, Search, X } from "lucide-react";
import {
  addHubProjectIssue,
  saveHubProjectDraft,
  hubError,
  type HubDetail,
  type InboxItem,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
import type { ProjectAsk } from "../lib/project-workspace";

export type ProjectIssueLoader = (
  search: string,
  page: number,
) => Promise<{ items: InboxItem[]; more: boolean }>;
export function ProjectComposer({
  detail,
  locked,
  gitlab,
  ask,
  close,
  loadIssues,
}: {
  detail: HubDetail;
  locked: boolean;
  gitlab: boolean;
  ask: ProjectAsk;
  close: () => void;
  loadIssues?: ProjectIssueLoader;
}) {
  const [tab, setTab] = useState<"draft" | "existing" | "url">(
    gitlab ? (loadIssues ? "existing" : "url") : "draft",
  );
  const [title, setTitle] = useState(""),
    [body, setBody] = useState(""),
    [url, setURL] = useState("");
  const [query, setQuery] = useState(""),
    [issues, setIssues] = useState<InboxItem[]>([]),
    [loading, setLoading] = useState(false),
    [error, setError] = useState(""),
    [page, setPage] = useState(0),
    [more, setMore] = useState(false);
  const request = useRef(0);
  useEffect(
    () => () => {
      request.current++;
    },
    [],
  );
  const load = async (append = false) => {
    if (!loadIssues) return;
    const id = ++request.current;
    setLoading(true);
    setError("");
    try {
      const result = await loadIssues(query, append ? page + 1 : 1);
      if (id !== request.current) return;
      setIssues((previous) =>
        append
          ? [
              ...previous,
              ...result.items.filter(
                (item) => !previous.some((value) => value.id === item.id),
              ),
            ]
          : result.items,
      );
      setPage(append ? page + 1 : 1);
      setMore(result.more);
    } catch (failure) {
      if (id === request.current) setError(hubError(failure));
    } finally {
      if (id === request.current) setLoading(false);
    }
  };
  const add = (value: string, label = value) =>
    ask(
      gitlab ? t("Move issue to the Open column?") : t("Add item to project?"),
      `${label}${gitlab ? `\n${t("This reopens the issue and removes its board column labels.")}` : ""}`,
      async (access) => {
        await addHubProjectIssue(access, detail, value);
        close();
      },
    );
  return (
    <section className="project-composer" aria-label={t("Add project item")}>
      <div className="project-composer-heading">
        <div>
          <h3>{t("Add to your project")}</h3>
          <p>{t("Capture an idea or connect work that already exists.")}</p>
        </div>
        <Button
          size="small"
          tip={t("Close")}
          onClick={() => {
            ask.cancel?.();
            close();
          }}
        >
          <X size={15} />
        </Button>
      </div>
      <div
        className="project-composer-tabs"
        role="group"
        aria-label={t("Item source")}
      >
        {!gitlab && (
          <Button
            size="small"
            kind={tab === "draft" ? "primary" : undefined}
            onClick={() => setTab("draft")}
          >
            <FilePlus2 size={13} />
            {t("New draft")}
          </Button>
        )}
        <Button
          size="small"
          kind={tab === "existing" ? "primary" : undefined}
          disabled={!loadIssues}
          onClick={() => {
            setTab("existing");
            if (!page) void load();
          }}
        >
          <Circle size={13} />
          {t("Repository issues")}
        </Button>
        <Button
          size="small"
          kind={tab === "url" ? "primary" : undefined}
          onClick={() => setTab("url")}
        >
          <Link size={13} />
          {t("Paste a link")}
        </Button>
      </div>
      {tab === "draft" ? (
        <div className="project-editor">
          <input
            className="input project-draft-title"
            aria-label={t("Draft title")}
            autoFocus
            placeholder={t("What needs to happen?")}
            value={title}
            disabled={locked}
            onChange={(event) => setTitle(event.target.value)}
          />
          <textarea
            className="textarea"
            aria-label={t("Draft description")}
            placeholder={t("Add context, a checklist, or acceptance criteria…")}
            rows={3}
            value={body}
            disabled={locked}
            onChange={(event) => setBody(event.target.value)}
          />
          <Button
            kind="primary"
            disabled={locked || !title.trim()}
            onClick={() =>
              ask(
                t("Create project draft?"),
                `${title}\n${body}`,
                async (access) => {
                  await saveHubProjectDraft(access, detail, title, body);
                  close();
                },
              )
            }
          >
            <Plus size={14} />
            {t("Create draft")}
          </Button>
        </div>
      ) : tab === "url" ? (
        <div className="project-add">
          <input
            className="input"
            aria-label={t("Issue URL")}
            placeholder={
              gitlab ? t("Issue URL") : t("Issue or pull request URL")
            }
            disabled={locked}
            value={url}
            onChange={(event) => setURL(event.target.value)}
          />
          <Button
            kind="primary"
            disabled={locked || !url.trim()}
            onClick={() => add(url)}
          >
            <Plus size={13} />
            {t("Add item")}
          </Button>
        </div>
      ) : (
        <div className="project-issue-picker">
          <div className="row">
            <input
              className="input"
              aria-label={t("Search repository issues")}
              placeholder={t("Search repository issues")}
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") void load();
              }}
            />
            <Button disabled={loading || locked} onClick={() => void load()}>
              <Search size={13} />
              {t("Search")}
            </Button>
          </div>
          {error && (
            <p className="error-text" role="alert">
              {error}
            </p>
          )}
          {issues.map((issue) => (
            <button
              className="project-issue-option"
              key={issue.id}
              disabled={locked}
              onClick={() => add(issue.url, `#${issue.number} ${issue.title}`)}
            >
              <Circle size={13} />
              <span>
                <strong>{issue.title}</strong>
                <small>
                  #{issue.number} · {issue.author}
                </small>
              </span>
              <Plus size={14} />
            </button>
          ))}
          {loading ? (
            <Spinner />
          ) : more ? (
            <Button size="small" onClick={() => void load(true)}>
              {t("Load more")}
            </Button>
          ) : (
            !issues.length && (
              <p className="hint">
                {page
                  ? t("No matching issues.")
                  : t("Search the open repository to choose an issue.")}
              </p>
            )
          )}
        </div>
      )}
    </section>
  );
}
