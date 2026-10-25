/** 브라우저 점검: npm run dev 후 /tests/commit-impact-preview.html. 저장소나 네이티브 호출은 실행하지 않는다. */
import "../src/app/styles/global.css";
import "../src/widgets/inspector/ui/inspector.css";
import { createRoot } from "react-dom/client";
import { useState } from "react";
import { gitch, type GraphReview } from "../src/entities/gitch";
import { RepoStore } from "../src/entities/repo";
import { ipc } from "../src/shared/api";
import { loadLanguage } from "../src/shared/i18n";
import { useObserve } from "../src/shared/lib";
import { CommitImpactPanel } from "../src/widgets/inspector/ui/CommitImpactPanel";

await loadLanguage("ko");
const store = new RepoStore();
store.path = "C:/fixture";
let stamp = "fixture-index";
let opened = 0;
const fixture: GraphReview = {
  schemaVersion: 1, tool: "gitch graph review", scope: "staged", stamp, snapshot: "fixture-tree", headSha: "fixture-head", branch: "feature/checkout", stale: false,
  changed: [{ path: "src/payments/checkout.ts", status: "M", analyzed: true }, { path: "assets/receipt.bin", status: "A", analyzed: false }],
  direct: [{ path: "src/screens/CheckoutView.tsx", depth: 1, via: ["src/payments/checkout.ts"], heuristic: false }],
  indirect: [{ path: "src/routes/shop.tsx", depth: 2, via: ["src/screens/CheckoutView.tsx"], heuristic: true }],
  tests: [{ path: "tests/payments/checkout.test.ts", kind: "dependency", depth: 1, heuristic: false }, { path: "tests/checkout.integration.test.ts", kind: "name", depth: 0, heuristic: true }],
  coverage: { changed: 2, analyzed: 1, unsupported: 1 },
  limitations: ["Static dependencies may omit dynamic references and unsupported syntax.", "Test candidates are inferred from dependency paths or file names; tests have not been run.", "Only staged files are selected; unstaged edits and untracked files are excluded."],
};
gitch.commitReview = async () => { await new Promise((resolve) => setTimeout(resolve, 250)); return structuredClone(fixture); };
gitch.commitReviewStamp = async () => stamp;
gitch.commitReviewGraph = async () => ({ file: "C:/fixture/staged-review.html", nodes: 4, hint: null });
ipc.openHtml = async () => { opened++; };
const stage = () => { store.status.staged = fixture.changed.map((f) => ({ path: f.path, staged: true, oldPath: null, kind: "modified" })); };
stage();

type Scenario = "ready" | "done" | "stale" | "failed" | "empty";
function scenario(value: Scenario) {
  stage(); stamp = "fixture-index";
  store.commitImpactVerifying = false;
  if (value === "ready") store.commitImpact = null;
  if (value === "done" || value === "stale") store.commitImpact = { kind: "done", result: { ...structuredClone(fixture), stale: value === "stale" }, revision: 0 };
  if (value === "failed") store.commitImpact = { kind: "failed", message: "Git Bash를 찾지 못했습니다. 설정에서 Git 설치 경로를 확인하세요." };
  if (value === "empty") { store.status.staged = []; store.commitImpact = { kind: "done", result: { ...structuredClone(fixture), changed: [], direct: [], indirect: [], tests: [], coverage: { changed: 0, analyzed: 0, unsupported: 0 } }, revision: 0 }; }
  store.changed();
}

function Preview() {
  useObserve(store);
  const [dark, setDark] = useState(false);
  const [narrow, setNarrow] = useState(false);
  return <main style={{ margin: "28px auto", maxWidth: narrow ? 360 : 520, padding: "0 16px 32px" }}>
    <h2 style={{ fontSize: 18, marginBottom: 12 }}>커밋 영향 분석 · 화면 점검</h2>
    <div className="row" style={{ flexWrap: "wrap", marginBottom: 14 }}>
      {(["ready", "done", "stale", "failed", "empty"] as const).map((value) => <button className="btn small" key={value} onClick={() => scenario(value)}>{value}</button>)}
      <button className="btn small" onClick={() => { document.documentElement.dataset.theme = dark ? "light" : "dark"; setDark(!dark); }}>테마</button>
      <button className="btn small" onClick={() => setNarrow(!narrow)}>패널 너비</button>
      <button className="btn small" onClick={() => void checks()}>UI 점검 실행</button>
    </div>
    <div id="impact-fixture"><CommitImpactPanel store={store} /></div>
    <pre id="impact-checks" style={{ whiteSpace: "pre-wrap", fontSize: 12 }} />
  </main>;
}

const waitFor = async (test: () => boolean) => {
  for (let i = 0; i < 80; i++) { if (test()) return; await new Promise((resolve) => setTimeout(resolve, 25)); }
  throw new Error("UI check timed out");
};
async function checks() {
  const output = document.getElementById("impact-checks")!;
  const host = document.getElementById("impact-fixture")!;
  const button = (text: string) => Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find((b) => b.textContent?.includes(text));
  const assert = (test: boolean, message: string) => { if (!test) throw new Error(message); };
  try {
    scenario("ready");
    await waitFor(() => !!button("스테이지 변경 분석"));
    button("스테이지 변경 분석")!.click();
    await waitFor(() => host.textContent?.includes("분석 중…") === true);
    await waitFor(() => host.textContent?.includes("직접 영향받는 파일") === true);
    assert(host.textContent!.includes("파일 이름 기준 · 추정"), "Name inference missing");
    assert(host.textContent!.includes("의존 관계 기준"), "Dependency candidate missing");
    assert(host.textContent!.includes("분석하지 못했습니다"), "Unsupported coverage missing");
    assert(host.textContent!.includes("테스트를 실행한 결과는 아닙니다"), "Test disclaimer missing");
    button("그래프로 열기")!.click();
    await waitFor(() => opened === 1);
    scenario("stale");
    await waitFor(() => button("그래프로 열기")?.disabled === true);
    assert(host.textContent!.includes("다시 분석하세요"), "Stale notice missing");
    scenario("failed");
    await waitFor(() => !!host.querySelector('[role="alert"]'));
    scenario("empty");
    await waitFor(() => host.textContent?.includes("스테이지 변경이 없습니다") === true);
    scenario("done");
    output.textContent = "PASS: actual analyze button, loading, dependency/name candidates, unsupported coverage, graph action, stale guard, failure and empty states.";
    output.dataset.result = "pass";
  } catch (error) { output.textContent = String(error); output.dataset.result = "fail"; }
}
createRoot(document.getElementById("root")!).render(<Preview />);
