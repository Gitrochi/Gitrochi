// gitch graph html 을 헤드리스 Chrome 으로 열어 본다(외부 모듈 없이 CDP — Node 22 의 fetch · WebSocket).
// 사용: node graph_browser.mjs <chrome> <html> <임시 폴더> → JSON 한 줄. 페이지 오류가 있거나 겹친 노드가 있으면 종료 코드 1
import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";

const [chromePath, html, tmp] = process.argv.slice(2);
const port = 9400 + Math.floor(Math.random() * 400);
const chrome = spawn(chromePath, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${tmp}/chrome`, "--no-first-run",
  "--no-default-browser-check", "--disable-gpu", "--enable-precise-memory-info", "--allow-file-access-from-files", "--use-mock-keychain", "--password-store=basic", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws, id = 0;
const waiting = new Map(), errors = [], externalRequests=[];
const send = (method, params = {}) => new Promise((r) => { const i = ++id; waiting.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
async function evaluate(expression) {
  const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.result.exceptionDetails) throw new Error(r.result.exceptionDetails.exception ? r.result.exceptionDetails.exception.description : r.result.exceptionDetails.text);
  return r.result.result.value;
}
let out={ok:false};
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
    else if (d.method === "Network.requestWillBeSent" && /^https?:/.test(d.params.request.url)) externalRequests.push(d.params.request.url);
    else if (d.method === "Runtime.exceptionThrown") errors.push(d.params.exceptionDetails.exception ? d.params.exceptionDetails.exception.description : d.params.exceptionDetails.text);
    else if (d.method === "Runtime.consoleAPICalled" && d.params.type === "error") errors.push(d.params.args.map((a) => a.value ?? a.description).join(" "));
  };
  await send("Runtime.enable"); await send("Page.enable"); await send("Network.enable");
  await send("Network.emulateNetworkConditions",{offline:true,latency:0,downloadThroughput:0,uploadThroughput:0});
  await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
  await send("Page.navigate", { url: `file://${html}#test` });
  for (let i = 0; i < 100; i++) { await sleep(100); if (await evaluate("!!window.gitchGraphTest")) break; }
  const first=await evaluate('({at:performance.now(),state:window.gitchGraphTest.state(),metrics:window.gitchGraphTest.metrics()})');
  const t0=Date.now();while(Date.now()-t0<20000&&await evaluate('window.gitchGraphTest.state().running'))await sleep(100);
  const result=await evaluate('({state:window.gitchGraphTest.state(),metrics:window.gitchGraphTest.metrics(),review:window.gitchGraphTest.benchmarkReview(),selection:window.gitchGraphTest.benchmarkSelection?.(),snapshot:(()=>{const cold=performance.now();window.gitchGraph?.snapshot();const coldMs=performance.now()-cold,warm=[];for(let i=0;i<5;i++){const t=performance.now();window.gitchGraph?.snapshot();warm.push(performance.now()-t);}return {coldMs,warmMs:warm};})(),memory:performance.memory?{usedJSHeapSize:performance.memory.usedJSHeapSize,totalJSHeapSize:performance.memory.totalJSHeapSize}:null,at:performance.now()})');
  if(process.env.GITCH_BENCH_REPORT_DIR) {
    const dir=process.env.GITCH_BENCH_REPORT_DIR;await mkdir(dir,{recursive:true});
    await writeFile(`${dir}/review.md`,await evaluate('window.gitchGraphTest.markdown()'));
    await writeFile(`${dir}/review.html`,await evaluate('window.gitchGraphTest.reportHtml()'));
  }
  out={ok:!errors.length&&!externalRequests.length,environment:{node:process.version,platform:process.platform,arch:process.arch},first,result,errors,externalRequests};
} catch(e) {out={ok:false,error:String(e)}} finally {try{ws?.close()}catch{}chrome.kill('SIGTERM')}
await writeFile(`${tmp}/performance.json`,JSON.stringify(out,null,2));
console.log(JSON.stringify(out));process.exit(out.ok?0:1);
