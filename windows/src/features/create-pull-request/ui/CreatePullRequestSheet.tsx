import { Sparkles } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { ai } from "@/entities/ai";
import { markdownLinks, providerInfo } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { Button, Checkbox, Frame, Markdown, Segmented, Spinner } from "@/shared/ui";

export function CreatePullRequestSheet({ store, close }: { store: RepoStore; close: () => void }) {
  const provider = store.target?.provider ?? "github";
  const [title, setTitle] = useState(() => {
    if (store.newPullRequestDraft?.branch === store.headBranch) return store.newPullRequestDraft.title;
    const b = store.headBranch ?? "";
    return (b.split("/").pop() ?? b).replace(/-/g, " ");
  });
  const saved = store.newPullRequestDraft?.branch === store.headBranch ? store.newPullRequestDraft : null;
  const [body, setBody] = useState(saved?.body ?? "");
  const [base, setBase] = useState(saved?.base ?? "");
  const [bases] = useState(() => store.pullRequestBaseCandidates());
  const [draft, setDraft] = useState(saved?.draft ?? false);
  const [generating, setGenerating] = useState(false);
  const [tab, setTab] = useState<"write" | "preview">("write");
  const links = useMemo(() => markdownLinks(store.target), [store.target]);
  useEffect(() => {
    void store.defaultBaseBranch().then((b) => b && setBase((cur) => cur || b));
  }, [store]);
  return (
    <Frame
      title={t("New {0}", providerInfo[provider].requestName)}
      confirm={t("Create")}
      width={640}
      canConfirm={!!title.trim() && !!base}
      close={close}
      onConfirm={() => void store.createPullRequest(title.trim(), body, base, draft)}
      leftFooter={store.status.upstream == null || store.status.ahead > 0 ? t("Pushes the current branch to {0} before creating.", store.target?.remote ?? t("Remotes")) : undefined}
    >
      <div className="row">
        <span className="mono">{store.headBranch}</span>
        <span className="muted">→</span>
        <select className="select" style={{ width: 240 }} value={base} onChange={(e) => setBase(e.target.value)}>
          {!base && <option value="">{t("Target branch")}</option>}
          {bases.map((b) => (
            <option key={b} value={b}>
              {b}
            </option>
          ))}
        </select>
      </div>
      <input className="input" placeholder={t("Title")} value={title} onChange={(e) => setTitle(e.target.value)} />
      <Segmented
        value={tab}
        onChange={setTab}
        options={[
          { value: "write", label: t("Write") },
          { value: "preview", label: t("Preview") },
        ]}
      />
      {tab === "write" ? (
        <textarea className="textarea" style={{ height: 220 }} value={body} placeholder={t("Description (Markdown)")} onChange={(e) => setBody(e.target.value)} />
      ) : (
        <div style={{ height: 220, overflow: "auto", padding: 10, border: "1px solid var(--border)", borderRadius: "var(--radius)" }}>
          {body.trim() ? <Markdown text={body} {...links} /> : <span className="muted">{t("Nothing to preview")}</span>}
        </div>
      )}
      <div className="row">
        <Checkbox checked={draft} onChange={setDraft} label={t("Draft")} />
        <span className="spacer" />
        {generating && <Spinner />}
        <Button
          disabled={generating || !base}
          onClick={() => {
            setGenerating(true);
            void store.draftPullRequest(base).then((d) => {
              if (d) {
                setTitle(d[0]);
                setBody(d[1]);
              }
              setGenerating(false);
            });
          }}
        >
          <Sparkles size={13} /> {" "}{t("Write with {0}", ai.shortFor("pullRequest"))}</Button>
      </div>
    </Frame>
  );
}
