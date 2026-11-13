/**
 * The real Flows page on fixture data, for looking at each state without an engine or a repository:
 * ?state=failed|running|passed|review|ready|empty, ?lang=ko, ?theme=dark.
 * The engine and file access are replaced in memory; the store, the model and every component are the app's own.
 */
import { createRoot } from "react-dom/client";
import { type FlowList, type FlowPlan, type FlowRunRow, flowEngine } from "../src/entities/flow";
import { RepoStore } from "../src/entities/repo";
import { ipc } from "../src/shared/api";
import { loadLanguage } from "../src/shared/i18n";
import { MenuHost, TooltipHost } from "../src/shared/ui";
import { FlowPanel } from "../src/widgets/sidebar";
import "../src/app/styles/global.css";

const params = new URLSearchParams(location.search);
const state = params.get("state") ?? "failed";
await loadLanguage(params.get("lang") ?? "en");
document.documentElement.dataset.theme = params.get("theme") ?? "light";

const minutesAgo = (minutes: number) => new Date(Date.now() - minutes * 60_000).toISOString();
const steps = [
  { id: "install", title: "Install dependencies", run: "npm ci", needs: [] as string[], src: ".gitch/flow.yml:8" },
  { id: "lint", title: "Check code style", run: "npm run lint", needs: ["install"], src: ".gitch/flow.yml:12" },
  { id: "unit", title: "Run unit tests", run: "npm test", needs: ["install"], src: ".gitch/flow.yml:16" },
  { id: "ui-tests", title: "Run UI tests", run: "xcodebuild test -scheme DesktopUITests -destination 'platform=macOS'", needs: ["install"], src: ".gitch/flow.yml:20" },
  { id: "package", title: "Package the app", run: "npm run package", needs: ["lint", "unit", "ui-tests"], src: ".gitch/flow.yml:25" },
];
const trusted = state !== "review";
const list: FlowList = {
  project: "desktop",
  trusted,
  suites: [],
  flows: state === "empty" ? [] : [
    { name: "verify", description: "Build and check this repository before sharing changes.", trigger: [], env: "local", nodes: steps.length, last: null },
    { name: "release", description: "Package the application and collect release artifacts.", trigger: [], env: "local", nodes: 3, last: null },
    { name: "docs", description: "Check links and spelling in the docs.", trigger: [], env: "local", nodes: 2, last: null },
  ],
};
const plan = (flow: string): FlowPlan => ({
  flow, env: "local", trust: { trusted }, outward: [], gates: [], services: [], warnings: [],
  nodes: (flow === "verify" ? steps : steps.slice(0, flow === "release" ? 3 : 2)).map((step) => ({ ...step, block: step.id.includes("test") || step.id === "unit" ? "test.junit" : "cmd", decision: "run" as const, executor: "local" })),
});
const outcome: Record<string, [string, number | null]> = state === "running"
  ? { install: ["PASSED", 22_000], lint: ["PASSED", 14_000], unit: ["PASSED", 100_000], "ui-tests": ["RUNNING", null], package: ["PENDING", null] }
  : state === "passed"
    ? { install: ["PASSED", 22_000], lint: ["PASSED", 14_000], unit: ["PASSED", 100_000], "ui-tests": ["PASSED", 126_000], package: ["PASSED", 31_000] }
    : { install: ["PASSED", 22_000], lint: ["PASSED", 14_000], unit: ["PASSED", 100_000], "ui-tests": ["FAILED", 130_000], package: ["SKIPPED", null] };
const runState = state === "running" ? "RUNNING" : state === "passed" ? "SUCCEEDED" : "FAILED";
const runs: FlowRunRow[] = state === "ready" || state === "empty" ? [] : [
  { runId: "20261113-0932-verify-24", flow: "verify", state: runState, running: state === "running", startedAt: minutesAgo(25), durationMs: state === "running" ? null : 152_000, signed: true },
  { runId: "20261112-1710-verify-23", flow: "verify", state: "SUCCEEDED", running: false, startedAt: minutesAgo(60 * 26), durationMs: 148_000, signed: true },
  { runId: "20261112-1101-release-7", flow: "release", state: "SUCCEEDED", running: false, startedAt: minutesAgo(60 * 30), durationMs: 96_000, signed: true },
];
const log = [
  "$ xcodebuild test -scheme DesktopUITests -destination 'platform=macOS'",
  ...Array.from({ length: 12 }, (_, index) => `Test Case 'SearchPanelUITests.testCase${index + 1}' passed (0.${index}12 seconds).`),
  "Test Suite 'SearchPanelUITests' started.",
  "Test Case 'SearchPanelUITests.testShowsResults' passed (2.104 seconds).",
  "Test Case 'SearchPanelUITests.testKeepsQueryAfterSwitch' started.",
  'SearchPanelUITests.swift:31: error: XCTAssertEqual failed: ("") is not equal to ("tooltip")',
  "Test Case 'SearchPanelUITests.testKeepsQueryAfterSwitch' failed (3.871 seconds).",
  "     Executed 38 tests, with 1 failure (0 unexpected) in 64.210 seconds",
  "** TEST FAILED **",
];
const events = () => {
  const lines: unknown[] = [{ type: "run.planned", data: { flow: "verify", nodes: plan("verify").nodes.map(({ id, title, block, needs }) => ({ id, title, block, needs })) } }];
  lines.push({ type: "run.state", data: { state: "RUNNING" } });
  for (const [id, [nodeState, durationMs]] of Object.entries(outcome)) {
    if (nodeState === "PENDING") continue;
    lines.push({ type: "node.state", node: id, data: { state: nodeState, durationMs } });
    if (id === "ui-tests") lines.push({ type: "log", node: id, data: { lines: state === "passed" ? log.slice(0, 15) : log } });
  }
  if (state !== "running") lines.push({ type: "run.done", data: { state: runState, exitCode: state === "passed" ? 0 : 1 } });
  return lines.map((line, index) => JSON.stringify({ seq: index + 1, at: minutesAgo(25), ...(line as object) })).join("\n") + "\n";
};
const record = (runId: string) => ({
  runId, flow: "verify", state: runState, running: state === "running", ...(state === "running" ? {} : { finishedAt: minutesAgo(22) }),
  nodes: Object.entries(outcome).map(([id, [nodeState, durationMs]]) => ({
    id, state: nodeState, durationMs,
    ...(id === "ui-tests" && nodeState === "FAILED" ? {
      failure: { description: "1 test failed: SearchPanelUITests.testKeepsQueryAfterSwitch" },
      verdicts: [{ rule: "E1", title: "Exit code is 0", result: "FAIL", observed: "got 65" }, { rule: "E2", title: "Finishes within 10m", result: "PASS" }],
    } : {}),
  })),
});

const engine = flowEngine as unknown as Record<string, unknown>;
engine.executable = async () => "fixture";
engine.hasFlowFile = async () => state !== "empty";
engine.list = async () => list;
engine.plan = async (flow: string) => plan(flow);
engine.runs = async () => runs;
engine.gate = async () => ({ gate: "OFF", flow: null });
engine.record = async (runId: string) => record(runId);
engine.events = async (runId: string, since: number) => (since === 0 && runId === runs[0]?.runId ? events() : "");
engine.trust = async () => { list.trusted = true; };
engine.cancel = async () => {};
engine.setGate = async () => {};
ipc.onFileDrop = async () => () => {};
ipc.readText = async () => null;
ipc.exists = async () => false;

const repository = new RepoStore();
repository.path = "/fixture/desktop";
createRoot(document.getElementById("root")!).render(
  <div style={{ display: "flex", flexDirection: "column", height: "100vh" }}>
    <FlowPanel store={repository} />
    <MenuHost />
    <TooltipHost />
  </div>,
);
