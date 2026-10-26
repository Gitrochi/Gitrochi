// 전역 스타일이 맨 먼저(조각별 CSS 는 그 뒤에, import 순서대로 붙는다)
import "./styles/global.css";
import { createRoot } from "react-dom/client";
import { agents } from "@/entities/agent";
import { ai } from "@/entities/ai";
import { accounts } from "@/entities/hosting";
import { workspace } from "@/entities/workspace";
import { ipc } from "@/shared/api";
import { env, settings } from "@/shared/config";
import { gitAvailable, tools, updater } from "@/shared/platform";
import { theme } from "@/shared/ui";
import { runSelfTest } from "./selftest";
import { App } from "./ui/App";
import { startAppLaunches } from "./lib/app-launch";
import { selfTestProgress } from "./lib/selftest-progress";
// 웹뷰 기본 우클릭 메뉴(새로 고침·검사 등)는 끄고, 앱 메뉴만 쓴다(입력 칸은 그대로)
window.addEventListener("contextmenu", (e) => {
  const el = e.target as HTMLElement;
  if (!el.closest("input, textarea, .xterm, .selectable")) e.preventDefault();
});

/** 언어를 정한 뒤에 불러온다(모듈 맨 위의 t() 가 고른 언어로 읽히게) */
export async function start() {
  theme.init();
  await selfTestProgress("Detecting external tools");
  await tools.detectAll();
  await selfTestProgress("Loading accounts, AI and agents");
  await Promise.all([accounts.load(), ai.load(), agents.init()]);
  const git = gitAvailable();
  createRoot(document.getElementById("root")!).render(<App gitMissing={!git} />);
  await selfTestProgress("Rendering app");
  // 첫 화면(로딩 애니메이션)이 그려진 뒤 창을 보여 준다 — 흰 화면 번쩍임 없이.
  // 숨긴 창에서는 requestAnimationFrame 이 돌지 않으므로 타이머로 부른다.
  setTimeout(() => void ipc.appReady(), 30);
  updater.start();
  // 윈도에서 못 찾은 AI CLI 는 WSL 에서 한 번 찾아 둔다(WSL 을 깨우느라 몇 초 걸릴 수 있어 뒤에서)
  if (!env.selftest) setTimeout(() => void tools.probeWsl(), 6000);
  window.addEventListener("beforeunload", () => void settings.flush());
  if (git) {
    const test = await runSelfTest();
    if (!test) await workspace.restore();
  } else {
    await workspace.restore();
  }
  await startAppLaunches();
}
