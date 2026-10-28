import { createRoot } from "react-dom/client";
import { RepoStore } from "../src/entities/repo";
import { RepositoryCodePanel, type RepositoryCodeSource } from "../src/widgets/local-workbench";
import { localWorkbenchSelfTest } from "../src/app/lib/local-workbench-selftest";
import { loadLanguage } from "../src/shared/i18n";
import "../src/app/styles/global.css";

const params = new URLSearchParams(location.search);
await loadLanguage(params.get("lang") ?? "en");
document.documentElement.dataset.theme = params.get("theme") ?? "light";
const host = document.getElementById("root")!;
const width = Number(params.get("width"));
if (Number.isFinite(width) && width >= 320 && width <= 1600) {
  host.style.width = `${width}px`;
  host.style.height = "780px";
  host.style.maxWidth = "100vw";
}
if (params.get("mode") === "selftest") {
  const [passed, details] = await localWorkbenchSelfTest();
  const result = document.createElement("pre");
  result.id = "code-reader-selftest-result";
  result.dataset.passed = String(passed);
  result.textContent = details;
  host.append(result);
} else {
  const store = new RepoStore(), oid = "a".repeat(40);
  store.path = "/fixture/desktop";
  store.headBranch = "main";
  store.localBranches = [{ name: "main", target: oid, upstream: "origin/main", ahead: 0, behind: 0, upstreamGone: false, isCurrent: true, isRemote: false }];
  store.tags = [{ name: "v1.0.0", target: oid }];
  const files: Record<string, string> = {
    "package.json": '{\n  "name": "desktop-workspace",\n  "version": "1.0.0",\n  "private": true\n}\n',
    "src/components/RepositoryCard.tsx": `import { useState } from "react";

interface Repository {
  name: string;
  branch: string;
  changedFiles: number;
}

/** Keep the next step close to the work. */
export function RepositoryCard({ repository }: { repository: Repository }) {
  const [expanded, setExpanded] = useState(false);
  const hasChanges = repository.changedFiles > 0;

  return (
    <article className="repository-card">
      <header>
        <h3>{repository.name}</h3>
        <span>{repository.branch}</span>
      </header>

      <button onClick={() => setExpanded(!expanded)}>
        {hasChanges ? "Review changes" : "Explore files"}
      </button>

      {expanded && (
        <p>Everything you need, right where you left it.</p>
      )}
    </article>
  );
}
`,
    "src/components/Sidebar.tsx": 'export const sections = ["Overview", "Code", "History"];\n',
    "src/hooks/useRepository.ts": 'export const useRepository = () => ({ branch: "main", changedFiles: 3 });\n',
    "src/utils/formatRepository.ts": `interface RepositorySummary {
  name: string;
  changedFiles: number;
}

export function formatRepository(repository: RepositorySummary): string {
  return repository.name + " · " + formatChangeCount(repository.changedFiles);
}

export function formatChangeCount(count: number): string {
  return count === 0 ? "Up to date" : count + " changed files";
}
`,
    "docs/overview.md": '# Repository workspace\n\nRead files and follow the code at your own pace.\n\n## Navigation\n\nUse quick open to find a file by name or path.\n\n## Reading\n\nJump between declarations with the outline, or go directly to a line.\n',
    "src/styles/theme.css": ':root {\n  color-scheme: light dark;\n  --space: 8px;\n}\n',
    "tests/repository.test.ts": 'import { expect, it } from "vitest";\nit("starts on main", () => expect("main").toBe("main"));\n',
  };
  if (params.get("large") === "1") {
    files["src/large.ts"] = "line\n".repeat(6000) + "export function tail() {}\n";
  }
  const entries = Object.entries(files).map(([path, text]) => ({ path, mode: "100644", oid, size: new TextEncoder().encode(text).length, kind: "file" as const }));
  const source: RepositoryCodeSource = {
    tree: async () => ({ revision: oid, entries, truncated: false }),
    blob: async (_repo, entry) => ({ text: files[entry.path] }),
    read: async (args) => args[0] === "log" ? "8b4c21f 2026-10-28 Demo contributor\nImprove repository navigation\n" : args[0] === "blame" ? "8b4c21f (Demo contributor 2026-10-28 1) export function RepositoryCard() {" : "",
  };
  createRoot(host).render(<RepositoryCodePanel store={store} source={source}/>);
}
