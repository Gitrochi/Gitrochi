import { useState } from "react";
import { gitch, graphRelations } from "@/entities/gitch";
import { workspace } from "@/entities/workspace";
import { ipc } from "@/shared/api";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";

const commands = [
  [
    "login github",
    "Start here",
    "Sign in with a browser and automatically connect your GitHub account.",
    "Settings > CLI > Add account > Connect with your browser",
  ],
  [
    "add · setup · list",
    "Start here",
    "Add a Git identity, register its SSH key, and view your accounts.",
    "Settings > CLI > Add account",
  ],
  [
    "install · uninstall",
    "Start here",
    "Enable or remove terminal and AI integration. The app already includes gitch.",
    "Settings > CLI > Enable terminal command",
  ],
  [
    "g · graph files",
    "Explore code",
    "See which source files import one another.",
    "Repository menu > Structure graph > File imports",
  ],
  [
    "g modules · changes · tree",
    "Explore code",
    "Explore package dependencies, files that change together, and folders.",
    "Repository menu > Structure graph",
  ],
  [
    "g affected · --precise · watch",
    "Explore code",
    "Follow the impact of edits, use compiler indexes, and refresh graphs as files change.",
    "Repository menu > Structure graph > Affected files / Precise references",
  ],
  [
    "g diff · check",
    "Explore code",
    "Compare dependency changes and check the repository's dependency rules.",
    "Repository menu > Changed dependencies / Dependency rules",
  ],
  [
    "g languages · index",
    "Explore code",
    "Check language support and learn how to generate a precise index.",
    "Language support and index instructions below",
  ],
  [
    "app",
    "Everyday work",
    "Open Gitrochi from a terminal; add a repository, file or line to jump there.",
    "gitch app . --file src/example.ts --line 12",
  ],
  [
    "status · ck · preflight",
    "Everyday work",
    "Check your repository, account, pending work and issues before committing or pushing.",
    "Account and check results above the commit box",
  ],
  [
    "c · p · pl · cp",
    "Everyday work",
    "Commit selected changes, push, pull, or commit and push together.",
    "Commit box and Push / Pull toolbar buttons",
  ],
  [
    "b · wt · up · sync",
    "Everyday work",
    "Create branches and worktrees, and bring in the latest changes.",
    "Branches, Worktrees, and the account menu",
  ],
  [
    "clone · fork · publish",
    "Everyday work",
    "Get a repository, create a fork, or publish a new repository.",
    "Welcome > Clone repository; repository publishing tools",
  ],
  [
    "pr · ci",
    "Everyday work",
    "Create or inspect a pull request and check its builds.",
    "PR and CI/CD tabs; connect a hosting account in Settings > Accounts",
  ],
  [
    "continue · abort",
    "Recovery",
    "Continue a conflicted operation after resolving files, or cancel it after reviewing the effect.",
    "Conflict screen and operation banner",
  ],
  [
    "rescue · undo · amend · fix",
    "Recovery",
    "Inspect backup points or repair an unpushed commit after reviewing the change.",
    "Account menu > Recovery; advanced commands need an explicit choice",
  ],
  [
    "doctor · scan · audit",
    "Accounts and tools",
    "Diagnose setup problems and inspect account rules across repositories.",
    "Settings > CLI > Check setup",
  ],
  [
    "use · unlock · ignore · protect",
    "Accounts and tools",
    "Choose an account and review repository locks, exclusions and protected branches.",
    "Commit account menu and branch context menu",
  ],
  [
    "org · config · auto · sign · ssh",
    "Accounts and tools",
    "Manage organization rules, shared settings, commit signing and SSH entries.",
    "Advanced terminal commands; inspect changes before applying them",
  ],
  [
    "ai · completion",
    "Accounts and tools",
    "Integrate AI tools and enable shell command suggestions.",
    "Terminal integration and command reference",
  ],
  [
    "export · import · migrate",
    "Accounts and tools",
    "Back up account configuration or migrate an older setup.",
    "Advanced terminal commands; exported configuration can contain private account details",
  ],
  [
    "prune · l · d · o · report",
    "Accounts and tools",
    "Review branches, history, diffs, the repository website and activity.",
    "Sidebar, commit graph, changes and repository menu",
  ],
  [
    "help · version · self-update",
    "Accounts and tools",
    "Read all command options, check the version, or update a standalone CLI.",
    "Gitrochi updates its bundled CLI together with the app",
  ],
];

export function GitchGuide({
  onAddAccount,
  onDoctor,
}: {
  onAddAccount: () => void;
  onDoctor: () => void;
}) {
  useObserve(workspace);
  const [query, setQuery] = useState("");
  const [busy, setBusy] = useState(false);
  const [output, setOutput] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const run = async (work: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      await work();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };
  const graph = (relation: "files" | "modules" | "changes" | "tree") =>
    run(async () => {
      const repo =
        workspace.active?.path ??
        (await ipc.pickFolder(t("Choose a Git repository")));
      if (!repo) return;
      const page = await gitch.graph(relation, repo);
      if (page.liveUrl) await ipc.openUrl(page.liveUrl);
      else await ipc.openHtml(page.file);
    });
  return (
    <div className="col" style={{ gap: 12 }}>
      <span className="hint">
        {t(
          "gitch is included in Gitrochi. You can add accounts and explore code here without a separate download or memorizing commands.",
        )}
      </span>
      <div className="form-section" style={{ gap: 8 }}>
        <strong>{t("Get started in three steps")}</strong>
        <span>{t("1. Add your Git username and commit email.")}</span>
        <span>
          {t(
            "2. Create or reuse an SSH key, register its public key with your server, and test the connection.",
          )}
        </span>
        <span>
          {t(
            "3. Open a repository. Enable the terminal command only if you want to use gitch outside the app.",
          )}
        </span>
        <div className="row">
          <Button kind="primary" onClick={onAddAccount}>
            {t("Add account")}
          </Button>
          <Button onClick={onDoctor}>{t("Check setup")}</Button>
        </div>
        <span className="hint">
          {t(
            "Git identity and SSH handle commits and SSH connections. Settings > Accounts connects GitHub/GitLab APIs for PRs and repository lists; connect it too when you need those features.",
          )}
        </span>
        <Button
          onClick={() =>
            window.dispatchEvent(
              new CustomEvent("gitrochi-open-settings", { detail: "accounts" }),
            )
          }
        >
          {t("Connect GitHub or GitLab for PRs")}
        </Button>
      </div>
      <div className="form-section" style={{ gap: 8 }}>
        <strong>{t("Try a structure graph — gitch g")}</strong>
        <span className="hint">
          {t(
            "Choose a graph below. If no repository is open, select one first. Graphs work before account setup.",
          )}
        </span>
        <div className="row" style={{ flexWrap: "wrap" }}>
          {graphRelations().map((r) => (
            <Button key={r.id} disabled={busy} onClick={() => void graph(r.id)}>
              {r.title}
            </Button>
          ))}
        </div>
      </div>
      <label className="col" style={{ gap: 4 }}>
        {t("Find a command or task")}
        <input
          className="input"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={t("Example: add, g, SSH, pull request")}
        />
      </label>
      {commands
        .filter((c) =>
          c
            .map((x) => t(x))
            .join(" ")
            .toLowerCase()
            .includes(query.toLowerCase()),
        )
        .map(([command, category, purpose, location]) => (
          <div className="form-section" key={command} style={{ gap: 5 }}>
            <div className="row">
              <code>gitch {command}</code>
              <span className="spacer" />
              <span className="faint">{t(category)}</span>
            </div>
            <span>{t(purpose)}</span>
            <span className="hint">{t(location)}</span>
          </div>
        ))}
      <div className="row" style={{ flexWrap: "wrap" }}>
        <Button
          disabled={busy}
          onClick={() =>
            void run(async () => setOutput(await gitch.commandHelp()))
          }
        >
          {t("All commands and options")}
        </Button>
        <Button
          onClick={() =>
            void run(() =>
              ipc.openUrl(
                "https://github.com/Gitrochi/Gitrochi/blob/main/tools/gitch/README.md",
              ),
            )
          }
        >
          {t("Open full guide")}
        </Button>
        <Button
          onClick={() =>
            void run(() =>
              ipc.openUrl(
                "https://github.com/Gitrochi/Gitrochi/blob/main/tools/gitch/SCIP.md",
              ),
            )
          }
        >
          {t("Precise index instructions")}
        </Button>
      </div>
      {busy && (
        <span className="row" role="status">
          <Spinner />
          {t("Working…")}
        </span>
      )}
      {error && (
        <span className="error-text selectable" role="alert">
          {error}
        </span>
      )}
      {output && (
        <pre
          className="mono selectable"
          style={{ whiteSpace: "pre-wrap", fontSize: 11, margin: 0 }}
        >
          {output}
        </pre>
      )}
    </div>
  );
}
