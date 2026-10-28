// Reproducible renderer workloads, not estimates of a user's repository.
import { execFileSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir, platform, arch, cpus } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const [chrome, destination] = process.argv.slice(2);
if (!chrome || !destination) throw new Error("Usage: node graph_scale_benchmark.mjs <chrome> <output-directory>");
const here = dirname(fileURLToPath(import.meta.url)), output = resolve(destination);
const temporary = await mkdtemp(join(tmpdir(), "gitch-graph-scale-")), repository = join(temporary, "fixture");
await mkdir(repository); await mkdir(output, { recursive: true });
const git = (...args) => execFileSync("git", args, { cwd: repository, stdio: "pipe" });
git("init", "-q"); git("config", "user.name", "Fixture"); git("config", "user.email", "fixture@example.com");
await writeFile(join(repository, "a.ts"), 'import "./b";\n'); await writeFile(join(repository, "b.ts"), "export const b=1;\n");
git("add", "a.ts", "b.ts"); git("commit", "-qm", "Graph: Create benchmark fixture");
const templatePath = join(temporary, "template.html");
execFileSync("bash", [join(here, "../gitch"), "graph", "files", "--format", "html", "--out", templatePath, "--no-open", repository], { stdio: "pipe", env: { ...process.env, GITCH_GRAPH_LANG: "en", GITCH_SWIFT_INDEX: "" } });
const template = await readFile(templatePath, "utf8"), pattern = /(<script id="graph-data" type="application\/json">)[\s\S]*?(<\/script>)/;
const base = JSON.parse(template.match(pattern)[0].replace(/^<script[^>]*>/, "").replace(/<\/script>$/, ""));
const result = { schemaVersion: 1, workload: "Synthetic static TS renderer; 40 files per folder and sparse cross-folder imports", environment: { node: process.version, platform: platform(), arch: arch(), cpu: cpus()[0]?.model }, runs: [] };
for (const count of [2000, 10000, 50000]) {
  const nodes = Array.from({ length: count }, (_, i) => ({ id: `src/group-${Math.floor(i / 40)}/file-${i}.ts`, path: `src/group-${Math.floor(i / 40)}/file-${i}.ts`, label: `file-${i}.ts`, kind: "file", group: "ts", lang: "ts", lines: 2, analysis: "static-import" }));
  const edges = [];
  for (let i = 1; i < count; i++) {
    edges.push({ source: nodes[i].id, target: nodes[i - 1].id, kind: "import", weight: 1, method: "static-import", evidence: [{ file: nodes[i].id, line: 1, method: "static-import" }] });
    if (i >= 40 && i % 40 === 0) edges.push({ source: nodes[i].id, target: nodes[i - 40].id, kind: "import", weight: 1, method: "static-import" });
  }
  const graph = { ...base.views.files, repo: "scale-fixture", repoPath: "", nodes, edges, snapshotID: `synthetic-${count}`, stats: { nodes: count, edges: edges.length, heuristicEdges: 0 }, coverage: { files: count, analyzed: count, unsupported: 0, edges: edges.length, heuristicEdges: 0, declaredEdges: edges.length, diagnostics: 0 } };
  const changes = nodes.slice(0, 3).map(node => ({ path: node.id, status: "M" }));
  const review = { ...base.review, branch: "benchmark", scope: "worktree", untracked: "excluded", snapshot: `synthetic-${count}`, changes, before: { nodes, edges }, current: { nodes, edges }, diff: { nodes: nodes.slice(0, 3).map(node => ({ ...node, status: "changed" })), edges: [], cycles: { new: [], changed: [], gone: [], existing: [] } }, rules: null, beforeRules: null };
  const data = { initial: "files", views: { files: graph }, review };
  const file = join(output, `graph-${count}.html`), run = join(output, `run-${count}`);
  await mkdir(run, { recursive: true });
  await writeFile(file, template.replace(pattern, (_, open, close) => open + JSON.stringify(data).replaceAll("<", "\\u003c") + close));
  try {
    const raw = execFileSync(process.execPath, [join(here, "graph_benchmark.mjs"), chrome, file, run], { encoding: "utf8", timeout: 180_000, maxBuffer: 4_000_000 });
    result.runs.push({ rawNodes: count, rawEdges: edges.length, ...JSON.parse(raw.trim()) });
  } catch (error) { result.runs.push({ rawNodes: count, ok: false, error: String(error), detail: error.stdout?.toString().slice(-2000) }); }
  await writeFile(join(output, "scale-results.json"), JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result.runs[result.runs.length - 1]));
}
process.exit(result.runs.every(run => run.ok) ? 0 : 1);
