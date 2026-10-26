// Exercise offline graph localization in real Chrome, using only Node's CDP primitives.
import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const [chromePath, directory, tmp] = process.argv.slice(2);
const path = "src/nested/very long file name with 변경 리뷰 Graph settings 相対パス intact.ts";
const filename = path.split("/").pop();
const labels = {
  en: { settings: "Graph settings", review: "Change review", folders: "Folders", copy: "Copy relative path", finder: "Reveal in Finder" },
  ko: { settings: "그래프 설정", review: "변경 리뷰", folders: "폴더 탐색", copy: "상대 경로 복사", finder: "Finder에서 보기" },
  ja: { settings: "グラフ設定", review: "変更レビュー", folders: "フォルダー", copy: "相対パスをコピー", finder: "Finderで表示" },
};
const port = 9800 + Math.floor(Math.random() * 300);
const chrome = spawn(chromePath, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${tmp}/locale-chrome`, "--no-first-run",
  "--no-default-browser-check", "--disable-gpu", "--allow-file-access-from-files", "--use-mock-keychain", "--password-store=basic", "about:blank"], { stdio: "ignore" });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let ws, nextId = 0, navigationId = 0, languageScript;
const waiting = new Map(), errors = [], requests = [], checks = [];
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = ++nextId;
  const timer = setTimeout(() => { waiting.delete(id); reject(new Error(`CDP timed out: ${method}`)); }, 20_000);
  waiting.set(id, { resolve, reject, timer });
  ws.send(JSON.stringify({ id, method, params }));
});
async function evaluate(expression) {
  const message = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (message.result.exceptionDetails) throw new Error(message.result.exceptionDetails.exception?.description ?? message.result.exceptionDetails.text);
  return message.result.result.value;
}
async function navigate(file, browserLanguage, expected) {
  if (languageScript) await send("Page.removeScriptToEvaluateOnNewDocument", { identifier: languageScript });
  const source = `Object.defineProperty(navigator,'language',{configurable:true,value:${JSON.stringify(browserLanguage)}});Object.defineProperty(navigator,'languages',{configurable:true,value:${JSON.stringify(browserLanguage ? [browserLanguage] : [])}});`;
  languageScript = (await send("Page.addScriptToEvaluateOnNewDocument", { source })).result.identifier;
  // A fresh URL forces a new document even when the same graph changes browser language.
  const url = `${pathToFileURL(`${directory}/${file}`).href}?locale-test=${++navigationId}#test`;
  await send("Page.navigate", { url });
  for (let i = 0; i < 100; i++) {
    await sleep(50);
    if (await evaluate(`!!window.gitchGraphTest&&location.href===${JSON.stringify(url)}&&navigator.language===${JSON.stringify(browserLanguage)}`)) break;
  }
  const ready = await evaluate(`({ready:!!window.gitchGraphTest,lang:document.documentElement.lang})`);
  if (!ready.ready || ready.lang !== expected) throw new Error(`${file}/${browserLanguage}: expected ${expected}, got ${JSON.stringify(ready)}`);
}
let output = { ok: false };
try {
  for (let i = 0; i < 100 && !ws; i++) {
    try {
      const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const page = pages.find(value => value.type === "page");
      if (page) {
        ws = new WebSocket(page.webSocketDebuggerUrl);
        await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
      }
    } catch { ws = undefined; }
    if (!ws) await sleep(100);
  }
  if (!ws) throw new Error("Chrome did not start");
  ws.onmessage = message => {
    const data = JSON.parse(message.data);
    if (data.id && waiting.has(data.id)) {
      const pending = waiting.get(data.id); waiting.delete(data.id); clearTimeout(pending.timer);
      if (data.error) pending.reject(new Error(data.error.message)); else pending.resolve(data);
    } else if (data.method === "Runtime.exceptionThrown") errors.push(data.params.exceptionDetails.exception?.description ?? data.params.exceptionDetails.text);
    else if (data.method === "Runtime.consoleAPICalled" && data.params.type === "error") errors.push(data.params.args.map(value => value.value ?? value.description).join(" "));
    else if (data.method === "Network.requestWillBeSent" && /^https?:/.test(data.params.request.url)) requests.push(data.params.request.url);
  };
  await send("Runtime.enable"); await send("Page.enable"); await send("Network.enable");
  await send("Network.emulateNetworkConditions", { offline: true, latency: 0, downloadThroughput: 0, uploadThroughput: 0 });
  await send("Emulation.setDeviceMetricsOverride", { width: 1366, height: 900, deviceScaleFactor: 1, mobile: false });

  // Exercise system fallback separately from navigator without requiring an installed OS locale.
  const automatic = await readFile(`${directory}/auto.html`, "utf8");
  const systemPage = automatic.replace(/(<script\b[^>]*id=["']graph-ui-locale["'][^>]*>)([\s\S]*?)(<\/script>)/, (_all, start, json, end) => {
    const metadata = JSON.parse(json); metadata.systemLanguage = "ja-JP";
    return start + JSON.stringify(metadata) + end;
  });
  if (systemPage === automatic) throw new Error("Missing graph-ui-locale metadata");
  await writeFile(`${directory}/system-ja.html`, systemPage);
  for (const [file, browserLanguage, code] of [
    ["en.html", "ko-KR", "en"], ["ko.html", "en-US", "ko"], ["ja.html", "ko-KR", "ja"],
    ["KO_kr.html", "en-US", "ko"], ["ja-JP.html", "en-US", "ja"], ["en-GB.html", "ja-JP", "en"],
    ["auto.html", "ko-KR", "ko"], ["auto.html", "ja-JP", "ja"], ["auto.html", "en-GB", "en"],
    ["system-ja.html", "", "ja"], ["auto.html", "fr-FR", "en"],
  ]) {
    await navigate(file, browserLanguage, code);
    const expected = labels[code];
    const check = await evaluate(`(async () => {
      const t=window.gitchGraphTest, path=${JSON.stringify(path)}, filename=${JSON.stringify(filename)}, expected=${JSON.stringify(expected)};
      const $=id=>document.getElementById(id), strip=value=>String(value).replaceAll(path,'').replaceAll(filename,'');
      const staticLabels=$('gear').textContent.includes(expected.settings)&&$('reviewTab').textContent.includes(expected.review)&&$('foldersNav').textContent.trim()===expected.folders;
      $('selectChanges').click();
      const row=[...document.querySelectorAll('#changeList .change')].find(value=>value.querySelector('[data-change]')?.dataset.change===path);
      const filenamePreserved=row?.querySelector('.file-name')?.textContent===filename;
      const readableActions=[...document.querySelectorAll('#dockTabs button')].every(button=>button.scrollWidth<=button.clientWidth+1)&&row.querySelector('.change-open').getBoundingClientRect().width>=44;
      t.select(path);
      const detail=$('info').textContent, selected=t.capture().selected===path&&detail.includes(filename);
      const detailLocalized=${JSON.stringify(code)}==='ko'||!/[가-힣]/.test(strip(detail));
      $('reviewTab').click();
      const dynamicReview=$('reviewDetail').querySelector('h2')?.textContent===expected.review;
      const reviewLocalized=${JSON.stringify(code)}==='ko'||!/[가-힣]/.test(strip($('reviewDetail').textContent));
      row.querySelector('.path-action').click();
      const menu=$('pathMenu'),relative=$('relativePathValue').textContent,absolute=$('absolutePathValue').textContent;
      const finder=new URL($('revealPath').href), repo=finder.searchParams.get('repo');
      const pathMenu=!menu.hidden&&$('copyRelativePath').textContent===expected.copy&&$('revealPath').textContent.includes(expected.finder)&&relative===path&&absolute===repo.replace(/\\/$/,'')+'/'+path&&finder.searchParams.get('file')===path;
      window.__localeClipboard=[];
      Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async value=>window.__localeClipboard.push(value)}});
      $('copyRelativePath').click();await new Promise(resolve=>setTimeout(resolve,30));
      const copied=window.__localeClipboard[0]===path;
      const copyLocalized=${JSON.stringify(code)}==='ko'||!/[가-힣]/.test($('pathFeedback').textContent);
      $('closePathMenu').click();
      const report=t.report(), markdown=t.markdown(), html=t.reportHtml(), parsed=new DOMParser().parseFromString(html,'text/html');
      const reports=markdown.includes(expected.review)&&parsed.querySelector('h1')?.textContent.includes(expected.review)&&parsed.documentElement.lang===${JSON.stringify(code)}&&report.selection.some(value=>value.path===path)&&markdown.includes(path)&&parsed.body.textContent.includes(path);
      const reportLocalized=${JSON.stringify(code)}==='ko'||(!/[가-힣]/.test(strip(markdown))&&!/[가-힣]/.test(strip(parsed.body.textContent)));
      const offline=parsed.querySelectorAll('script,[src]').length===0;
      return {ok:staticLabels&&filenamePreserved&&readableActions&&selected&&detailLocalized&&dynamicReview&&reviewLocalized&&pathMenu&&copied&&copyLocalized&&reports&&reportLocalized&&offline,staticLabels,filenamePreserved,readableActions,selected,detailLocalized,dynamicReview,reviewLocalized,pathMenu,copied,copyLocalized,reports,reportLocalized,offline,
        actual:{settings:$('gear').textContent,review:$('reviewDetail').querySelector('h2')?.textContent,folders:$('foldersNav').textContent,copy:$('copyRelativePath').textContent,finder:$('revealPath').textContent},
        leftovers:${JSON.stringify(code)}==='ko'?[]:[strip(detail),strip($('reviewDetail').textContent),strip(markdown),strip(parsed.body.textContent)].flatMap(value=>value.match(/[^\\n]{0,30}[가-힣][^\\n]{0,70}/g)||[]).slice(0,8)};
    })()`);
    checks.push({ file, browserLanguage, language: code, ...check });
    if (process.env.GITCH_TEST_ARTIFACT_DIR && file === `${code}.html`) {
      await mkdir(process.env.GITCH_TEST_ARTIFACT_DIR, { recursive: true });
      const screenshot = await send("Page.captureScreenshot", { format: "png" });
      await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-locale-${code}.png`, Buffer.from(screenshot.result.data, "base64"));
    }
  }
  output = { ok: !errors.length && !requests.length && checks.every(value => value.ok), errors, requests, checks };
} catch (error) {
  output = { ok: false, errors: [...errors, String(error?.message ?? error)], checks };
} finally {
  for (const pending of waiting.values()) clearTimeout(pending.timer);
  try { ws?.close(); } catch { /* The page may already be closed. */ }
  chrome.kill("SIGTERM");
}
console.log(JSON.stringify(output));
process.exit(output.ok ? 0 : 1);
