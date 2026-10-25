// gitch graph html 을 헤드리스 Chrome 으로 열어 본다(외부 모듈 없이 CDP — Node 22 의 fetch · WebSocket).
// 사용: node graph_browser.mjs <chrome> <html> <임시 폴더> → JSON 한 줄. 페이지 오류가 있거나 겹친 노드가 있으면 종료 코드 1
import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";

const [chromePath, html, tmp] = process.argv.slice(2);
const port = 9400 + Math.floor(Math.random() * 400);
const chrome = spawn(chromePath, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${tmp}/chrome`, "--no-first-run",
  "--no-default-browser-check", "--disable-gpu", "--allow-file-access-from-files", "--use-mock-keychain", "--password-store=basic", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws, id = 0;
const waiting = new Map(), errors = [];
const send = (method, params = {}) => new Promise((r) => { const i = ++id; waiting.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
async function evaluate(expression) {
  const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.result.exceptionDetails) throw new Error(r.result.exceptionDetails.exception ? r.result.exceptionDetails.exception.description : r.result.exceptionDetails.text);
  return r.result.result.value;
}
// 배치를 바꾸고 멈출 때까지 기다린 뒤 겹친 쌍의 수
const settle = (tab, layout, style) => `(async () => {
  const t = window.gitchGraphTest, click = (sel) => { const b = document.querySelector(sel); if (b && !b.classList.contains("on")) b.click(); };
  if (${JSON.stringify(tab)}) document.dispatchEvent(new KeyboardEvent("keydown", { key: ${JSON.stringify(tab)} }));
  if (${JSON.stringify(style)}) click('#style button[data-v="${style}"]');
  click('#layout button[data-v="${layout}"]');
  const t0 = performance.now();
  while (t.state().running && performance.now() - t0 < 20000) await new Promise((r) => setTimeout(r, 100));
  await new Promise((r) => setTimeout(r, 700));
  const s = t.state();
  return { rel: s.rel, layout: s.layout, style: s.style, nodes: s.nodes, overlaps: t.overlaps() };
})()`;
let out = { ok: false };
try {
  for (let i = 0; i < 100 && !ws; i++) {
    try {
      const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === "page");
      if (page) { ws = new WebSocket(page.webSocketDebuggerUrl); await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; }); }
    } catch (e) { ws = undefined; }
    if (!ws) await sleep(100);
  }
  if (!ws) throw new Error("Chrome 이 뜨지 않음");
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); }
    else if (d.method === "Runtime.exceptionThrown") errors.push(d.params.exceptionDetails.exception ? d.params.exceptionDetails.exception.description : d.params.exceptionDetails.text);
    else if (d.method === "Runtime.consoleAPICalled" && d.params.type === "error") errors.push(d.params.args.map((a) => a.value ?? a.description).join(" "));
  };
  await send("Runtime.enable"); await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
  await send("Page.navigate", { url: `file://${html}#test` });
  for (let i = 0; i < 100; i++) { await sleep(100); if (await evaluate("!!window.gitchGraphTest")) break; }
  const checks = [];
  for (const [tab, layout, style] of [["", "force", "dot"], ["", "force", "box"], ["", "pack", ""], ["", "layers", "box"], ["", "stars", "dot"], ["", "stars", "box"], ["2", "layers", "box"], ["2", "force", "box"], ["4", "tidy", "box"], ["4", "radial", "dot"], ["4", "pack", ""]])
    checks.push(await evaluate(settle(tab, layout, style)));
  // 별자리 → 힘 → 폴더 단위에서 별자리 → 파일 단위로 돌아오면 별자리를 지금 설정으로 다시 잡아야 한다(꼭짓점 별이 제자리, 벗어난 거리 0)
  const starTrip = await evaluate(`(async () => {
    const t = window.gitchGraphTest, wait = (ms) => new Promise((r) => setTimeout(r, ms)), click = (sel) => document.querySelector(sel).click();
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "1" })); await wait(300);
    click('#layout button[data-v="stars"]'); await wait(700);
    click('#layout button[data-v="force"]'); await wait(700);
    click('#unit button[data-v="folder"]'); await wait(700);
    click('#layout button[data-v="stars"]'); await wait(700);
    click('#unit button[data-v="file"]'); await wait(1200);
    const s = t.state();
    return { unit: s.unit, layout: s.layout, drift: t.starDrift() };
  })()`);
  const languages = await evaluate(`(() => {
    const select = document.getElementById("lang"), t = window.gitchGraphTest;
    const options = [...select.options].map((o) => o.value), checks = [];
    for (const key of ["1", "2", "4"]) {
      document.dispatchEvent(new KeyboardEvent("keydown", { key }));
      for (const lang of ["ts", "js", "java", "python", "csharp", "php"]) {
        select.value = lang; select.dispatchEvent(new Event("change"));
        const visible = t.visible().filter((n) => n.kind !== "package");
        checks.push({ key, lang, nodes: visible.length, ok: options.includes(lang) && visible.length > 0 && visible.every((n) => n.langs.includes(lang)) });
      }
      if (key !== "2") {
        select.value = "docker"; select.dispatchEvent(new Event("change"));
        const visible = t.visible(); checks.push({ key, lang: "docker", nodes: visible.length, ok: visible.length > 0 && visible.every((n) => n.langs.includes("docker")) });
      }
    }
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "1" }));
    document.querySelector('#layout button[data-v="force"]').click();
    document.querySelector('#unit button[data-v="folder"]').click();
    select.value = "java"; select.dispatchEvent(new Event("change"));
    const folders = t.visible(); checks.push({ folder: true, ok: folders.length > 0 && folders.every((n) => n.langs.includes("java")) });
    select.value = "all"; select.dispatchEvent(new Event("change"));
    return { options, checks, ok: !["astro", "png", "constructor", "toString"].some((lang) => options.includes(lang)) && checks.every((c) => c.ok) };
  })()`);
  const png = await evaluate(`new Promise((res) => { const orig = HTMLAnchorElement.prototype.click; HTMLAnchorElement.prototype.click = function () { HTMLAnchorElement.prototype.click = orig; fetch(this.href).then((x) => x.blob()).then((b) => res({ name: this.download, type: b.type, bytes: b.size })); }; document.getElementById("png").click(); })`);
  const views = await evaluate(`(() => {
    const t = window.gitchGraphTest;
    document.dispatchEvent(new KeyboardEvent("keydown", {key:"1"}));
    document.querySelector('#layout button[data-v="force"]').click();
    document.querySelector('#unit button[data-v="file"]').click();
    t.select("packages/a/src/f1.ts");
    const data=t.capture(); data.filters.lang="ts"; data.filters.names=true; data.camera.k=1.7;
    t.restore(data);
    const input=document.getElementById("viewName"); input.value="__proto__"; document.getElementById("saveView").click();
    document.getElementById("lang").value="java"; document.getElementById("lang").dispatchEvent(new Event("change"));
    const saved=document.getElementById("savedViews"); saved.value="__proto__"; saved.dispatchEvent(new Event("change"));
    const restored=t.capture(); let rejected=false; try {t.restore({schemaVersion:999});}catch {rejected=true;}
    const detail=document.querySelector("#info details.evidence"); detail?.querySelector("summary").click();
    const link=detail?.querySelector("a"), source=document.querySelector("#info a.source-link");
    const evidence=!!link && link.href.startsWith("gitrochi://open?") && new URL(link.href).searchParams.get("line")==="1";
    const result={ok:restored.filters.lang==="ts" && restored.filters.names && restored.camera.k===1.7 && restored.selected==="packages/a/src/f1.ts" && rejected && evidence && !!source,
      selected:restored.selected, language:restored.filters.lang, zoom:restored.camera.k, rejected, evidence};
    document.dispatchEvent(new KeyboardEvent("keydown", {key:"3"})); t.select("packages/a/src/f1.ts");
    const commit=[...document.querySelectorAll("#info details.evidence a")].find(a=>new URL(a.href).searchParams.has("commit"));
    result.history=!!commit && /^[0-9a-f]{40}$/.test(new URL(commit.href).searchParams.get("commit")); result.ok &&=result.history;
    return result;
  })()`);
  if (process.env.GITCH_TEST_ARTIFACT_DIR) {
    await mkdir(process.env.GITCH_TEST_ARTIFACT_DIR, { recursive: true });
    await evaluate(`(() => { document.dispatchEvent(new KeyboardEvent("keydown", {key:"1"})); window.gitchGraphTest.select("packages/a/src/f1.ts"); const details=document.querySelector("#info details.evidence"); if(details) details.open=true; document.getElementById("gear").click(); for(const d of document.querySelectorAll("#panel > details")) d.open=d.querySelector("#saveView")!==null; document.getElementById("deleteView").click(); document.getElementById("viewName").value="TS 참조"; document.getElementById("saveView").click(); document.getElementById("info").scrollTop=document.getElementById("info").scrollHeight; })()`);
    for (const theme of ["dark", "light"]) {
      await evaluate(`document.documentElement.dataset.theme !== ${JSON.stringify(theme)} && document.getElementById("theme").click(); window.gitchGraphTest.redraw(2)`);
      const shot = await send("Page.captureScreenshot", { format: "png" });
      await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-${theme}.png`, Buffer.from(shot.result.data, "base64"));
    }
  }
  const tripOk = starTrip.unit === "file" && starTrip.layout === "stars" && starTrip.drift === 0;
  out = { ok: !errors.length && checks.every((c) => c.overlaps === 0) && tripOk && languages.ok && views.ok && png.type === "image/png", errors, checks, starTrip, languages, views, png };
} catch (e) {
  out = { ok: false, errors: [...errors, String(e && e.message || e)] };
} finally {
  try { ws && ws.close(); } catch (e) { /* 이미 닫힘 */ }
  chrome.kill("SIGTERM");
}
console.log(JSON.stringify(out));
process.exit(out.ok ? 0 : 1);
