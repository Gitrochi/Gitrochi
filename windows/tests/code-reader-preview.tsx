import { createRoot } from "react-dom/client";
import { RepoStore } from "../src/entities/repo";
import { RepositoryCodePanel, type RepositoryCodeSource, type RepositoryEditorSource } from "../src/widgets/local-workbench";
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
    "web/preview.html": `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><link rel="stylesheet" href="preview.css"></head>
<body><main class="page"><header><div class="brand"><img src="mark.png" alt="Workspace mark"> FIELDNOTES</div><span class="tag">A little room to think</span></header>
<section class="hero"><span class="eyebrow">YOUR NEXT GOOD IDEA STARTS HERE</span><h1>Make space<br>for what matters.</h1><p>A calm workspace for the notes, plans and small discoveries that move your work forward.</p><a class="button" href="https://example.invalid/blocked-link">Explore the workspace <span>↗</span></a></section>
<section class="cards"><article><span class="number">01</span><h2>Capture the spark</h2><p>Keep a thought before it slips away.</p></article><article><span class="number">02</span><h2>Connect the pieces</h2><p>Find a clearer path through your ideas.</p></article><article><span class="number">03</span><h2>Make it happen</h2><p>Turn a small plan into a useful next step.</p></article></section><footer>Designed for a more thoughtful day.<span>Built one idea at a time.</span></footer></main>
<script>document.body.setAttribute("data-unsafe-executed", "yes");</script>
</body></html>`,
    "web/preview.css": `@import "tokens.css";
*{box-sizing:border-box}body{margin:0;background:#f8f7f2;color:#252b27;font-family:system-ui,sans-serif}.page{max-width:1050px;margin:auto;padding:30px 38px}header,footer{display:flex;justify-content:space-between;align-items:center;gap:20px}.brand{display:flex;align-items:center;gap:10px;font-size:12px;letter-spacing:2px;font-weight:750}.brand img{width:26px;height:26px;border-radius:50%;background:#bfda79}.tag{font-size:11px;color:#697269}.hero{padding:56px 0 44px;border-bottom:1px solid #d9dfd3}.eyebrow{font-size:10px;letter-spacing:2px;color:#6c7b5f;font-weight:700}h1{font-size:clamp(35px,5vw,65px);letter-spacing:-2.8px;line-height:1.05;margin:20px 0;color:var(--ink)}.hero p{max-width:440px;color:#71796d;line-height:1.8;font-size:13px}.button{display:inline-flex;gap:28px;align-items:center;background:#d7ec99;padding:13px 18px;border-radius:6px;font-size:12px;font-weight:650;color:#253820;text-decoration:none;margin-top:10px}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:24px;padding:28px 0 35px}.number{color:#8e9c7e;font-size:11px}.cards h2{font-size:14px;margin:12px 0 8px}.cards p{font-size:11px;color:#7b8375;line-height:1.6}footer{border-top:1px solid #d9dfd3;padding-top:22px;font-size:9px;color:#818a79}@media(max-width:500px){.page{padding:24px}.tag{display:none}.hero{padding:40px 0}.cards{grid-template-columns:1fr;gap:16px}footer{align-items:flex-start;flex-direction:column;gap:8px}}`,
    "web/tokens.css": ':root { --ink: #293d25; }\n',
    "tests/repository.test.ts": 'import { expect, it } from "vitest";\nit("starts on main", () => expect("main").toBe("main"));\n',
  };
  if (params.get("large") === "1") {
    files["src/large.ts"] = "line\n".repeat(6000) + "export function tail() {}\n";
  }
  const pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
  const entries = Object.entries(files).map(([path, text], index) => ({ path, mode: "100644", oid: (index + 1).toString(16).padStart(40, "0"), size: new TextEncoder().encode(text).length, kind: "file" as const }));
  entries.push({ path: "web/mark.png", mode: "100644", oid: "b".repeat(40), size: atob(pixel).length, kind: "file" });
  const source: RepositoryCodeSource = {
    tree: async () => ({ revision: oid, entries, truncated: false }),
    blob: async (_repo, entry) => entry.path === "web/mark.png" ? { image: `data:image/png;base64,${pixel}` } : { text: files[entry.path] },
    read: async (args) => args[0] === "log" ? "8b4c21f 2026-10-28 Demo contributor\nImprove repository navigation\n" : args[0] === "blame" ? "8b4c21f (Demo contributor 2026-10-28 1) export function RepositoryCard() {" : "",
  };
  const editorSource: RepositoryEditorSource = {
    list: async () => [
      { id: "system", name: "System default", available: true, supportsFolders: true },
      { id: "vscode", name: "Visual Studio Code", available: true, supportsFolders: true },
      { id: "intellij", name: "IntelliJ IDEA", available: true, supportsFolders: true },
      { id: "notepad", name: "Notepad", available: true, supportsFolders: false },
      { id: "notepad-plus-plus", name: "Notepad++", available: false, supportsFolders: false },
    ],
    open: async (repo, editorID, file) => { host.dataset.editor = editorID; host.dataset.editorRepo = repo; host.dataset.editorFile = file ?? ""; },
  };
  createRoot(host).render(<RepositoryCodePanel store={store} source={source} editorSource={editorSource}/>);
}
