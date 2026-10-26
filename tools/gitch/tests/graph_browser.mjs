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
const waiting = new Map(), errors = [], externalRequests=[];
const send = (method, params = {}) => new Promise((r) => { const i = ++id; waiting.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
async function evaluate(expression) {
  const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.result.exceptionDetails) throw new Error(r.result.exceptionDetails.exception ? r.result.exceptionDetails.exception.description : r.result.exceptionDetails.text);
  return r.result.result.value;
}
async function clickElement(selector, { index = 0, shift = false } = {}) {
  const point = await evaluate(`(() => {
    const e=[...document.querySelectorAll(${JSON.stringify(selector)})][${index}];
    if(!e)throw new Error('Missing click target: '+${JSON.stringify(selector)});
    e.scrollIntoView({block:'nearest',inline:'nearest'});
    const r=e.getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2};
  })()`);
  const modifiers = shift ? 8 : 0;
  await send('Input.dispatchMouseEvent', { type:'mousePressed', ...point, button:'left', clickCount:1, modifiers });
  await send('Input.dispatchMouseEvent', { type:'mouseReleased', ...point, button:'left', clickCount:1, modifiers });
}
async function escapeDialog() {
  await send('Input.dispatchKeyEvent', {type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27,nativeVirtualKeyCode:27});
  await send('Input.dispatchKeyEvent', {type:'keyUp',key:'Escape',code:'Escape',windowsVirtualKeyCode:27,nativeVirtualKeyCode:27});
}
const folderSelector = (path) => `#folders .folder-scope[data-folder=${JSON.stringify(path)}]`;
const folderToggleSelector = (path) => `#folders .folder-row:has(> .folder-scope[data-folder=${JSON.stringify(path)}]) > .folder-toggle`;
async function expandFolder(path) {
  const selector=folderToggleSelector(path);
  if(await evaluate(`document.querySelector(${JSON.stringify(selector)})?.getAttribute('aria-expanded')==='false'`))await clickElement(selector);
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
    else if (d.method === "Network.requestWillBeSent" && /^https?:/.test(d.params.request.url)) externalRequests.push(d.params.request.url);
    else if (d.method === "Runtime.exceptionThrown") errors.push(d.params.exceptionDetails.exception ? d.params.exceptionDetails.exception.description : d.params.exceptionDetails.text);
    else if (d.method === "Runtime.consoleAPICalled" && d.params.type === "error") errors.push(d.params.args.map((a) => a.value ?? a.description).join(" "));
  };
  await send("Runtime.enable"); await send("Page.enable"); await send("Network.enable");
  await send("Network.emulateNetworkConditions",{offline:true,latency:0,downloadThroughput:0,uploadThroughput:0});
  await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
  await send("Page.navigate", { url: `file://${html}#test` });
  for (let i = 0; i < 100; i++) { await sleep(100); if (await evaluate("!!window.gitchGraphTest")) break; }
  const dockInitial = await evaluate(`(() => {
    const dock=document.getElementById('rightDock'), visible=e=>!!e&&!e.hidden&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';
    return {settings:visible(document.getElementById('panel')),review:visible(document.getElementById('reviewDetail')),
      tabs:['gear','reviewTab','infoTab'].every(id=>visible(document.getElementById(id))&&dock?.contains(document.getElementById(id))),
      selected:document.getElementById('gear')?.getAttribute('aria-selected')==='true'};
  })()`);
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
  const review = await evaluate(`(() => {
    const t=window.gitchGraphTest, depth=document.getElementById('impactDepth');
    document.getElementById('selectChanges').click();
    const initial=t.review();
    depth.value='1';depth.dispatchEvent(new Event('change'));const one=t.review();
    depth.value='3';depth.dispatchEvent(new Event('change'));const three=t.review();
    const paths=[...three.direct,...three.indirect].map(r=>r.id);
    const check=document.getElementById('heur');check.checked=false;check.dispatchEvent(new Event('change'));const trusted=t.review();
    check.checked=true;check.dispatchEvent(new Event('change'));
    const candidate=three.tests.find(c=>c.path.endsWith('review.test.ts'));
    document.getElementById('clearChanges').click();const empty=t.review();
    const inputs=[...document.querySelectorAll('[data-change]')];
    const dotnet=inputs.find(e=>e.dataset.change==='dotnet/App.cs');dotnet.checked=true;dotnet.dispatchEvent(new Event('change'));const noTests=t.review();
    document.getElementById('selectChanges').click();
    const q=document.getElementById('q');q.value='not-found-sentinel';q.dispatchEvent(new Event('input'));const noResults=document.getElementById('searchResults').textContent.includes('검색 결과가 없습니다');q.value='';q.dispatchEvent(new Event('input'));
    return {ok:initial.seeds.length>=4 && one.indirect.length===0 && three.indirect.length>0 && paths.length===new Set(paths).size && three.direct.some(r=>r.id==='swift/Caller.swift') && !trusted.direct.some(r=>r.id==='swift/Caller.swift') && candidate?.reasons.some(r=>r.kind==='direct') && three.priorities.violations.some(v=>v.existing) && three.priorities.violations.some(v=>!v.existing) && three.priorities.rows.some(c=>c.rules>0) && empty.seeds.length===0 && empty.tests.length===0 && noTests.tests.length===0 && noResults,
      seeds:initial.seeds.length,direct:three.direct.length,indirect:three.indirect.length,tests:three.tests.length,noTests:noTests.tests.length,noResults};
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
  const sharing = await evaluate(`(() => {
    const t=window.gitchGraphTest;
    document.dispatchEvent(new KeyboardEvent('keydown',{key:'1'}));
    document.getElementById('clearChanges').click();
    const check=[...document.querySelectorAll('[data-change]')].find(e=>e.dataset.change==='packages/a/src/f1.ts');check.checked=true;check.dispatchEvent(new Event('change'));
    const depth=document.getElementById('impactDepth');depth.value='1';depth.dispatchEvent(new Event('change'));
    const report=t.report(),md=t.markdown(),html=t.reportHtml();
    const privacy=!JSON.stringify(report).includes('repoPath')&&!md.includes('/Users/')&&!html.includes('/Users/');
    const filter=report.selection.length===1&&report.selection[0].path==='packages/a/src/f1.ts'&&report.indirect.length===0;
    t.select('packages/a/src/f1.ts');t.select('packages/a/src/f2.ts');document.getElementById('navBack').click();const back=t.capture().selected;document.getElementById('navForward').click();const forward=t.capture().selected;
    const old=t.capture();t.restore({...old,snapshot:'stale-snapshot',selected:'packages/a/src/f1.ts',positions:[['packages/a/src/f1.ts',999999,999999]]});const stale=t.capture().selected===null;
    const search=document.getElementById('q');search.focus();const rel=t.state().rel;search.dispatchEvent(new KeyboardEvent('keydown',{key:'4',bubbles:true}));const inputGuard=t.state().rel===rel;search.blur();
    document.getElementById('selectChanges').click();depth.value='3';depth.dispatchEvent(new Event('change'));
    const escaped=t.reportHtml().includes('&lt;b&gt;&amp;');
    return {ok:privacy&&filter&&stale&&inputGuard&&escaped&&back==='packages/a/src/f1.ts'&&forward==='packages/a/src/f2.ts',privacy,filter,stale,inputGuard,escaped,back,forward,mdBytes:new Blob([md]).size,htmlBytes:new Blob([html]).size};
  })()`);

  const selectionRestore = await evaluate('window.gitchGraphTest.capture()');
  await evaluate(`(() => {
    const t=window.gitchGraphTest,s=t.capture();s.query='';s.filters.lang='all';s.filters.tests=true;s.review.folder='';s.panels.leftClosed=false;t.restore(s);
    document.getElementById('clearChanges').click();
  })()`);
  const selectionInitial = await evaluate(`(() => {
    const rows=[...document.querySelectorAll('#changeList .change')],input=rows[0]?.querySelector('[data-change]'),r=input?.getBoundingClientRect();
    return {paths:rows.map(e=>e.querySelector('[data-change]').dataset.change),native:input?.type==='checkbox',size:!!r&&r.width>=20&&r.height>=20,
      separate:rows.every(e=>e.querySelector('.change-select')?.contains(e.querySelector('[data-change]'))&&!e.querySelector('.change-select button')&&e.querySelector('.change-open[data-file]')?.parentElement===e)};
  })()`);
  await clickElement('#changeList .change-select .file-name');
  const labelSelection = await evaluate(`(() => {
    const input=document.querySelector('#changeList [data-change]');return {checked:input.checked,focused:document.activeElement===input,seeds:window.gitchGraphTest.review().seeds.map(c=>c.path)};
  })()`);
  await send('Input.dispatchKeyEvent', { type:'keyDown', key:' ', code:'Space', windowsVirtualKeyCode:32, nativeVirtualKeyCode:32 });
  await send('Input.dispatchKeyEvent', { type:'keyUp', key:' ', code:'Space', windowsVirtualKeyCode:32, nativeVirtualKeyCode:32 });
  const keyboardSelection = await evaluate(`(() => {
    const input=document.querySelector('#changeList [data-change]');return {unchecked:!input.checked,focused:document.activeElement===input,seeds:window.gitchGraphTest.review().seeds.length};
  })()`);
  const beforeDetail = await evaluate('window.gitchGraphTest.capture().review.chosen');
  await clickElement('#changeList .change-open[data-file]');
  const detailSelection = await evaluate(`(() => {
    const t=window.gitchGraphTest,s=t.capture();return {unchanged:JSON.stringify(s.review.chosen)===${JSON.stringify(JSON.stringify(beforeDetail))},selected:s.selected,info:document.getElementById('infoTab').getAttribute('aria-selected')==='true'};
  })()`);
  const specialIndex = selectionInitial.paths.findIndex(path=>path.includes('<b>&'));
  if(specialIndex>=0)await clickElement('#changeList .change-select .file-name', { index:specialIndex });
  const specialSelection = await evaluate(`(() => {
    const path=${JSON.stringify(selectionInitial.paths[specialIndex] || '')},row=[...document.querySelectorAll('#changeList .change')].find(e=>e.querySelector('[data-change]').dataset.change===path);
    return !!row&&row.querySelector('[data-change]').checked&&row.querySelector('.file-name').textContent===path.split('/').pop()&&!row.querySelector('.change-select b')&&window.gitchGraphTest.capture().review.chosen.includes(path);
  })()`);
  await evaluate(`(() => {
    document.getElementById('clearChanges').click();const q=document.getElementById('q');q.value='packages/a/src/';q.dispatchEvent(new Event('input'));
  })()`);
  const rangePaths = await evaluate("[...document.querySelectorAll('#changeList [data-change]')].map(e=>e.dataset.change)");
  await clickElement('#changeList .change-select .file-name');
  await clickElement('#changeList .change-select .file-name', { index:rangePaths.length - 1, shift:true });
  const rangeSelection = await evaluate(`(() => {
    const inputs=[...document.querySelectorAll('#changeList [data-change]')];return {all:inputs.every(e=>e.checked),chosen:window.gitchGraphTest.capture().review.chosen};
  })()`);
  await clickElement('#changeList .change-select .file-name', { index:rangePaths.length - 1 });
  await clickElement('#changeList .change-select .file-name', { shift:true });
  const rangeCleared = await evaluate("[...document.querySelectorAll('#changeList [data-change]')].every(e=>!e.checked)");
  await evaluate(`(() => {
    const q=document.getElementById('q');q.value='';q.dispatchEvent(new Event('input'));document.getElementById('selectChanges').click();
    const list=document.getElementById('changeList');list.scrollTop=list.scrollHeight-list.clientHeight;
  })()`);
  const scrollBefore = await evaluate("document.getElementById('changeList').scrollTop");
  await clickElement('#changeList .change-select .file-name', { index:selectionInitial.paths.length - 1 });
  const scrollPreserved = await evaluate(`Math.abs(document.getElementById('changeList').scrollTop-${scrollBefore})<=1`);
  const collapsedHeight = await evaluate("document.getElementById('changeList').getBoundingClientRect().height");
  await clickElement('#expandChanges');
  const expandedSelection = await evaluate(`(() => {
    const height=document.getElementById('changeList').getBoundingClientRect().height;
    return {height,expanded:document.getElementById('top').classList.contains('changesExpanded'),pressed:document.getElementById('expandChanges').getAttribute('aria-pressed')==='true',increased:height>${collapsedHeight}+10};
  })()`);
  await clickElement('#expandChanges');
  const expansionRestored = await evaluate(`!document.getElementById('top').classList.contains('changesExpanded')&&document.getElementById('expandChanges').getAttribute('aria-pressed')==='false'&&Math.abs(document.getElementById('changeList').getBoundingClientRect().height-${collapsedHeight})<=1`);
  const selectionUX = {
    ok:selectionInitial.paths.length>=4&&selectionInitial.native&&selectionInitial.size&&selectionInitial.separate&&labelSelection.checked&&labelSelection.focused&&labelSelection.seeds.length===1&&labelSelection.seeds[0]===selectionInitial.paths[0]&&keyboardSelection.unchecked&&keyboardSelection.focused&&keyboardSelection.seeds===0&&detailSelection.unchanged&&detailSelection.selected===selectionInitial.paths[0]&&detailSelection.info&&specialSelection&&rangePaths.length>=3&&rangeSelection.all&&rangeSelection.chosen.length===rangePaths.length&&rangeCleared&&scrollPreserved&&expandedSelection.expanded&&expandedSelection.pressed&&expandedSelection.increased&&expansionRestored,
    initial:selectionInitial,label:labelSelection,keyboard:keyboardSelection,detail:detailSelection,specialSelection,range:{paths:rangePaths,...rangeSelection,cleared:rangeCleared},scrollPreserved,expanded:expandedSelection,expansionRestored
  };
  await evaluate(`window.gitchGraphTest.restore(${JSON.stringify(selectionRestore)});document.getElementById('selectChanges').click()`);

  const explorerRestore=await evaluate('window.gitchGraphTest.capture()');
  await evaluate(`(() => {
    const t=window.gitchGraphTest,s=t.capture();s.query='';s.review.folder='';s.filters.lang='all';s.panels.leftClosed=false;t.restore(s);
  })()`);
  await clickElement('#foldersNav');
  const folderInitial=await evaluate(`(() => {
    const $=id=>document.getElementById(id),visible=e=>!!e&&!e.hidden&&e.getClientRects().length>0;
    return {tabs:['changesNav','foldersNav'].every(id=>$(id).getAttribute('role')==='tab'),
      selected:$('foldersNav').getAttribute('aria-selected')==='true',visible:visible($('exploreFolders'))&&!visible($('changeList')),
      siblings:$('exploreFolders').parentElement===$('changeList').parentElement&&$('reviewNav').contains($('exploreFolders')),
      tree:!!$('folders').querySelector('ul > li ul > li'),ancestors:['packages/','packages/a/','packages/a/src/','removed/','removed/history/'].every(path=>[...$('folders').querySelectorAll('[data-folder]')].some(b=>b.dataset.folder===path)),
      noTruncation:!$('folders').textContent.includes('개 생략')};
  })()`);
  await expandFolder('archive/');
  const completeFolders=await evaluate(`(() => {
    const buttons=[...document.querySelectorAll('#folders .folder-scope')];
    return {count:buttons.filter(b=>/^archive\\/folder-\\d+\\/$/.test(b.dataset.folder)).length,last:!!document.querySelector(${JSON.stringify(folderSelector('archive/folder-125/'))})};
  })()`);
  await clickElement(folderSelector('archive/folder-125/'));
  const lastFolder=await evaluate(`window.gitchGraphTest.capture().review.folder==='archive/folder-125/'&&document.getElementById('changesNav').getAttribute('aria-selected')==='true'`);
  const unchangedFolderRestore=await evaluate(`(() => {const t=window.gitchGraphTest,s=t.capture();t.restore(s);return t.capture().review.folder==='archive/folder-125/';})()`);
  await clickElement('#folderScope button[data-folder=""]');
  await clickElement('#foldersNav');
  const beforeToggle=await evaluate(`document.querySelector(${JSON.stringify(folderToggleSelector('packages/'))}).getAttribute('aria-expanded')`);
  await clickElement(folderToggleSelector('packages/'));
  const folderToggle=await evaluate(`document.querySelector(${JSON.stringify(folderToggleSelector('packages/'))}).getAttribute('aria-expanded')!==${JSON.stringify(beforeToggle)}`);
  await expandFolder('packages/');
  await expandFolder('packages/a/');
  await evaluate(`(() => {const q=document.getElementById('q');q.value='f1';q.dispatchEvent(new Event('input'));})()`);
  await clickElement(folderSelector('packages/a/'));
  const scopedSearch=await evaluate(`(() => {
    const s=window.gitchGraphTest.capture(),paths=[...document.querySelectorAll('#changeList [data-change]')].map(e=>e.dataset.change);
    return {folder:s.review.folder,query:s.query,input:document.getElementById('q').value,paths,scope:document.getElementById('folderScope').textContent.includes('packages')};
  })()`);
  await clickElement('#folderScope button[data-folder=""]');
  const resetScope=await evaluate(`window.gitchGraphTest.capture().review.folder===''&&window.gitchGraphTest.capture().query==='f1'&&document.getElementById('q').value==='f1'`);
  await evaluate(`(() => {const q=document.getElementById('q');q.value='';q.dispatchEvent(new Event('input'));})()`);
  await clickElement('#foldersNav');
  await expandFolder('packages/');await expandFolder('packages/a/');
  await clickElement(folderSelector('packages/a/src/'));
  const prefixScope=await evaluate(`(() => {const paths=[...document.querySelectorAll('#changeList [data-change]')].map(e=>e.dataset.change);return paths.length>0&&paths.every(path=>path.startsWith('packages/a/src/'))&&!paths.some(path=>path.startsWith('packages/a/src2/'));})()`);
  await clickElement('#folderScope button[data-folder=""]');
  await clickElement('#foldersNav');await expandFolder('removed/');
  await clickElement(folderSelector('removed/history/'));
  const deletedScope=await evaluate(`(() => {const paths=[...document.querySelectorAll('#changeList [data-change]')].map(e=>e.dataset.change);return paths.length===1&&paths[0]==='removed/history/only.ts';})()`);
  await clickElement('#folderScope button[data-folder=""]');
  const readableFiles=await evaluate(`(() => {
    const groups=[...document.querySelectorAll('#changeList .change-group')],names=[...document.querySelectorAll('#changeList .file-name')],long=names.find(e=>e.textContent.startsWith('long file name'));
    const style=long&&getComputedStyle(long),height=long?.getBoundingClientRect().height||0,line=style?(parseFloat(style.lineHeight)||parseFloat(style.fontSize)*1.2):0;
    return {groups:groups.length,heading:[...document.querySelectorAll('#changeList .change-folder-name')].some(e=>e.textContent.includes('packages/a/src/nested')),
      wrapping:!!long&&style.whiteSpace!=='nowrap'&&style.textOverflow!=='ellipsis'&&height>line*1.2,
      separate:[...document.querySelectorAll('#changeList .change')].every(e=>e.querySelector('.path-action')?.parentElement===e&&!e.querySelector('.change-select .path-action'))};
  })()`);
  await evaluate(`(() => {
    window.__gitchClipboardWrites=[];window.__gitchClipboardDescriptor=Object.getOwnPropertyDescriptor(navigator,'clipboard');
    Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async text=>{window.__gitchClipboardWrites.push(text);}}});
  })()`);
  const menuPath='packages/a/src/nested/long file name that stays readable in the changed file list.ts';
  const filePathAction=`#changeList .path-action[data-path=${JSON.stringify(menuPath)}]`;
  const chosenBeforePath=await evaluate('JSON.stringify(window.gitchGraphTest.capture().review.chosen)');
  await clickElement(filePathAction);
  const pathMenu=await evaluate(`(() => {
    const menu=document.getElementById('pathMenu'),relative=document.getElementById('relativePathValue').textContent,absolute=document.getElementById('absolutePathValue').textContent;
    const link=new URL(document.getElementById('revealPath').href),repo=link.searchParams.get('repo');
    return {open:!menu.hidden&&menu.getClientRects().length>0,relative,absolute,link:link.protocol==='gitrochi:'&&link.hostname==='open'&&link.searchParams.get('view')==='finder'&&link.searchParams.get('file')===${JSON.stringify(menuPath)}&&!!repo,
      absoluteMatches:!!repo&&absolute===repo.replace(/\\/$/,'')+'/'+${JSON.stringify(menuPath)},unchanged:JSON.stringify(window.gitchGraphTest.capture().review.chosen)===${JSON.stringify(chosenBeforePath)}};
  })()`);
  await clickElement('#copyRelativePath');
  const relativeCopy=await evaluate(`window.__gitchClipboardWrites.at(-1)===${JSON.stringify(menuPath)}`);
  await escapeDialog();
  await clickElement(filePathAction);
  await clickElement('#copyAbsolutePath');
  const absoluteCopy=await evaluate(`window.__gitchClipboardWrites.at(-1)===${JSON.stringify(pathMenu.absolute)}`);
  await escapeDialog();
  const menuClosed=await evaluate("document.getElementById('pathMenu').hidden||!document.getElementById('pathMenu').getClientRects().length");
  await clickElement('#foldersNav');
  await expandFolder('packages/');
  await clickElement('#folders .path-action[data-path="packages"]');
  const folderPathMenu=await evaluate(`(() => {
    const link=new URL(document.getElementById('revealPath').href);
    return !document.getElementById('pathMenu').hidden&&document.getElementById('relativePathValue').textContent==='packages'&&link.searchParams.get('file')==='packages';
  })()`);
  await escapeDialog();
  await evaluate(`(() => {
    if(window.__gitchClipboardDescriptor)Object.defineProperty(navigator,'clipboard',window.__gitchClipboardDescriptor);else delete navigator.clipboard;
    delete window.__gitchClipboardDescriptor;delete window.__gitchClipboardWrites;
  })()`);
  const explorerUX={
    ok:folderInitial.tabs&&folderInitial.selected&&folderInitial.visible&&folderInitial.siblings&&folderInitial.tree&&folderInitial.ancestors&&folderInitial.noTruncation&&completeFolders.count>=125&&completeFolders.last&&lastFolder&&unchangedFolderRestore&&folderToggle&&scopedSearch.folder==='packages/a/'&&scopedSearch.query==='f1'&&scopedSearch.input==='f1'&&scopedSearch.paths.length>0&&scopedSearch.paths.every(path=>path.startsWith('packages/a/')&&path.includes('f1'))&&scopedSearch.scope&&resetScope&&prefixScope&&deletedScope&&readableFiles.groups>0&&readableFiles.heading&&readableFiles.wrapping&&readableFiles.separate&&pathMenu.open&&pathMenu.relative===menuPath&&pathMenu.link&&pathMenu.absoluteMatches&&pathMenu.unchanged&&relativeCopy&&absoluteCopy&&menuClosed&&folderPathMenu,
    initial:folderInitial,complete:completeFolders,lastFolder,unchangedFolderRestore,folderToggle,scopedSearch,resetScope,prefixScope,deletedScope,readableFiles,pathMenu,relativeCopy,absoluteCopy,menuClosed,folderPathMenu
  };
  await evaluate(`window.gitchGraphTest.restore(${JSON.stringify(explorerRestore)});document.getElementById('changesNav').click()`);

  const dock = await evaluate(`(() => {
    const t=window.gitchGraphTest, $=id=>document.getElementById(id), visible=e=>!!e&&!e.hidden&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';
    const controls=['ext','heur','tests','orph','onlyFound','minDeg','local','localDepth','groups','layout','colorBy','sizeBy','arrows','names','fade','size','width','center','repel','link','dist','animate','viewName','savedViews','saveView','deleteView','exportView','importView'];
    const preserved=controls.every(id=>$('panel').contains($(id))),nested=['panel','reviewDetail','info','table','ana'].every(id=>$('rightDock').contains($(id)));
    if(document.body.classList.contains('rightClosed'))$('rightToggle').click();
    $('gear').click();
    const settings=visible($('panel'))&&!visible($('reviewDetail'))&&$('gear').getAttribute('aria-selected')==='true';
    $('reviewTab').click();
    const review=visible($('reviewDetail'))&&!visible($('panel'))&&$('reviewTab').getAttribute('aria-selected')==='true';
    t.select('packages/a/src/f1.ts');
    const selection=visible($('info'))&&!visible($('reviewDetail'))&&$('infoTab').getAttribute('aria-selected')==='true';
    const close=$('info').querySelector('.head .icon-btn');close?.click();
    const closeReturnsReview=t.capture().selected===null&&visible($('reviewDetail'))&&$('reviewTab').getAttribute('aria-selected')==='true';
    $('gear').click();$('rightToggle').click();
    const collapsed=!visible($('rightDock'))&&$('rightToggle').getAttribute('aria-expanded')==='false';
    $('rightToggle').click();
    const reopened=visible($('rightDock'))&&visible($('panel'))&&$('rightToggle').getAttribute('aria-expanded')==='true';
    $('list').click();
    const table=visible($('table'))&&!visible($('panel'))&&[...$('dockTabs').querySelectorAll('button')].some(b=>b.tabIndex===0);
    $('tableClose').click();
    const tableReturnsSettings=visible($('panel'));
    $('anaBtn').click();const analysis=visible($('ana'));$('anaClose').click();
    return {ok:preserved&&nested&&settings&&review&&selection&&closeReturnsReview&&collapsed&&reopened&&table&&tableReturnsSettings&&analysis,preserved,nested,settings,review,selection,closeReturnsReview,collapsed,reopened,table,tableReturnsSettings,analysis};
  })()`);
  const dockLayouts=[];
  for(const [width,height] of [[1366,768],[1000,768],[900,600],[390,844],[680,800]]) {
    await send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
    await sleep(100);
    for(const tab of ['gear','reviewTab']) {
      await evaluate(`document.getElementById(${JSON.stringify(tab)}).click()`);
      dockLayouts.push(await evaluate(`(() => {
        const visible=e=>!!e&&!e.hidden&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden';
        const rect=id=>{const e=document.getElementById(id);if(!visible(e))return null;const r=e.getBoundingClientRect();return {id,left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height};};
        const head=rect('masthead'),tools=rect('tools'),panels=['top','rightDock'].map(rect).filter(Boolean),overlap=(a,b)=>a.left<b.right-1&&a.right>b.left+1&&a.top<b.bottom-1&&a.bottom>b.top+1;
        const noOverlap=panels.every(p=>!overlap(p,head)&&!overlap(p,tools))&&(panels.length<2||!overlap(panels[0],panels[1]));
        const blockers=[head,tools,...panels].filter(Boolean),xs=[0,innerWidth,...blockers.flatMap(p=>[Math.max(0,p.left),Math.min(innerWidth,p.right)])],ys=[0,innerHeight,...blockers.flatMap(p=>[Math.max(0,p.top),Math.min(innerHeight,p.bottom)])];
        let center={width:0,height:0,area:0};
        for(const left of xs)for(const right of xs)for(const top of ys)for(const bottom of ys){const r={left,right,top,bottom};if(right-left<120||bottom-top<80||blockers.some(b=>overlap(r,b)))continue;const area=(right-left)*(bottom-top);if(area>center.area)center={width:right-left,height:bottom-top,area};}
        const viewport=window.gitchGraphTest.state().viewport,graphVisible=!!viewport&&viewport.r>viewport.l&&viewport.b>viewport.t;
        return {width:innerWidth,tab:${JSON.stringify(tab)},ok:noOverlap&&center.area>0&&graphVisible,noOverlap,center,viewport,panels};
      })()`));
    }
  }
  const narrowExplore=await evaluate(`(() => {
    const visible=e=>!!e&&!e.hidden&&e.getClientRects().length>0, $=id=>document.getElementById(id);
    document.dispatchEvent(new KeyboardEvent('keydown',{key:'/'}));
    const explorer=visible($('top'))&&!visible($('rightDock'))&&$('leftToggle').getAttribute('aria-expanded')==='true';
    const searchFocused=document.activeElement===$('q');$('q').blur();
    const panel=$('top').getBoundingClientRect(),head=$('masthead').getBoundingClientRect(),tools=$('tools').getBoundingClientRect(),viewport=window.gitchGraphTest.state().viewport;
    const changes=$('changeList').getBoundingClientRect(),geometry=panel.top>=head.bottom-1&&panel.bottom<=tools.top+1&&viewport.r>viewport.l&&viewport.b>viewport.t&&changes.height>=100&&changes.width>=panel.width-40;
    $('rightToggle').click();
    const restored=visible($('rightDock'))&&!visible($('top'))&&$('rightToggle').getAttribute('aria-expanded')==='true';
    return {ok:explorer&&searchFocused&&geometry&&restored,explorer,searchFocused,geometry,restored};
  })()`);
  dock.initial=dockInitial;dock.layouts=dockLayouts;dock.narrowExplore=narrowExplore;
  dock.ok &&=dockInitial.settings&&!dockInitial.review&&dockInitial.tabs&&dockInitial.selected&&dockLayouts.every(l=>l.ok)&&narrowExplore.ok;

  if (process.env.GITCH_TEST_ARTIFACT_DIR) {
    await mkdir(process.env.GITCH_TEST_ARTIFACT_DIR,{recursive:true});
    await evaluate(`(() => {const t=window.gitchGraphTest,s=t.capture();s.snapshot='screenshot-reset';s.selected=null;s.filters.names=true;s.filters.lang='all';s.query='';s.display.files.style='dot';s.display.files.layout='force';t.restore(s);document.getElementById('gear').click();})()`);
    for(let i=0;i<200;i++){if(!await evaluate('window.gitchGraphTest.state().running'))break;await sleep(100);}
    await send('Emulation.setDeviceMetricsOverride',{width:1366,height:768,deviceScaleFactor:1,mobile:false});
    await evaluate(`(() => {const top=document.getElementById('top');document.body.classList.remove('leftClosed','narrowExplore');if(!top.classList.contains('changesExpanded'))document.getElementById('expandChanges').click();document.getElementById('selectChanges').click();document.getElementById('changeList').scrollTop=0;})()`);
    for(const theme of ['dark','light']) {
      await evaluate(`document.documentElement.dataset.theme !== ${JSON.stringify(theme)} && document.getElementById('theme').click();window.gitchGraphTest.redraw(4)`);await sleep(300);
      const shot=await send('Page.captureScreenshot',{format:'png'});
      await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-selection-${theme}-1366.png`,Buffer.from(shot.result.data,'base64'));
      const clip=await evaluate(`(() => {const r=document.getElementById('top').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height,scale:1};})()`);
      const panelShot=await send('Page.captureScreenshot',{format:'png',clip});
      await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-selection-panel-${theme}-1366.png`,Buffer.from(panelShot.result.data,'base64'));
    }
    for(const [width,height] of [[1366,768],[680,800]]) {
      await send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
      await evaluate(`(() => {
        document.body.classList.remove('leftClosed');if(innerWidth<=900)document.body.classList.add('narrowExplore');
        document.getElementById('foldersNav').click();document.getElementById('folders').scrollTop=0;
      })()`);
      await clickElement('#collapseFolders');
      await expandFolder('packages/');await expandFolder('packages/a/');await expandFolder('packages/a/src/');
      await evaluate("document.getElementById('folders').scrollTop=0");
      for(const theme of ['dark','light']) {
        await evaluate(`document.documentElement.dataset.theme !== ${JSON.stringify(theme)} && document.getElementById('theme').click();window.gitchGraphTest.redraw(4)`);await sleep(300);
        const treeShot=await send('Page.captureScreenshot',{format:'png'});
        await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-folders-${theme}-${width}.png`,Buffer.from(treeShot.result.data,'base64'));
        await clickElement('#folders .path-action[data-path="packages/a/src"]');await sleep(100);
        const pathShot=await send('Page.captureScreenshot',{format:'png'});
        await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-path-menu-${theme}-${width}.png`,Buffer.from(pathShot.result.data,'base64'));
        await escapeDialog();
      }
      await clickElement('#changesNav');
      for(const theme of ['dark','light']) {
        await evaluate(`document.documentElement.dataset.theme !== ${JSON.stringify(theme)} && document.getElementById('theme').click();document.getElementById('changeList').scrollTop=0;window.gitchGraphTest.redraw(4)`);await sleep(200);
        const changedShot=await send('Page.captureScreenshot',{format:'png'});
        await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-readable-files-${theme}-${width}.png`,Buffer.from(changedShot.result.data,'base64'));
      }
    }
    await evaluate("document.getElementById('expandChanges').click()");
    for(const [width,height] of [[1366,768],[1000,768],[680,800]]) {
      await send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
      for(const theme of ['dark','light']) {
        await evaluate(`document.documentElement.dataset.theme !== ${JSON.stringify(theme)} && document.getElementById('theme').click();document.getElementById('gear').click();document.getElementById('fit').click();window.gitchGraphTest.redraw(4)`);await sleep(600);
        const shot=await send('Page.captureScreenshot',{format:'png'});
        await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-settings-${theme}-${width}.png`,Buffer.from(shot.result.data,'base64'));
        if(width===1366)await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-${theme}.png`,Buffer.from(shot.result.data,'base64'));
      }
    }
    await evaluate(`document.getElementById('leftToggle').click();document.getElementById('fit').click();window.gitchGraphTest.redraw(4)`);await sleep(600);
    const exploreShot=await send('Page.captureScreenshot',{format:'png'});
    await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-explore-680.png`,Buffer.from(exploreShot.result.data,'base64'));
    await evaluate(`document.getElementById('rightToggle').click()`);
  }
  const reportFile=`${tmp}/standalone-review.html`;
  await writeFile(reportFile,await evaluate('window.gitchGraphTest.reportHtml()'));
  if(process.env.GITCH_TEST_ARTIFACT_DIR) {
    await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/review-report.html`,await evaluate('window.gitchGraphTest.reportHtml()'));
    await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/review-report.md`,await evaluate('window.gitchGraphTest.markdown()'));
    for(const [width,height] of [[1366,768],[1000,768],[680,800]]) {
      await send('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
      await evaluate(`document.documentElement.dataset.theme !== 'dark' && document.getElementById('theme').click();document.getElementById('reviewTab').click();document.getElementById('fit').click();window.gitchGraphTest.redraw(4)`);
      await sleep(600);
      const shot=await send('Page.captureScreenshot',{format:'png'});
      await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-review-${width}.png`,Buffer.from(shot.result.data,'base64'));
    }
  }
  await send('Page.navigate',{url:`file://${reportFile}`});await sleep(300);
  const offline=await evaluate(`document.querySelectorAll('script,[src]').length===0 && document.querySelector('h1')?.textContent.includes('변경 리뷰') && document.querySelector('main').textContent.includes('테스트 후보')`);
  const tripOk = starTrip.unit === "file" && starTrip.layout === "stars" && starTrip.drift === 0;
  out = { ok: !errors.length && checks.every((c) => c.overlaps === 0) && tripOk && languages.ok && views.ok && review.ok && sharing.ok && selectionUX.ok && explorerUX.ok && dock.ok && offline && !externalRequests.length && png.type === "image/png", errors, checks, starTrip, languages, views, review, sharing, selectionUX, explorerUX, dock, offline, externalRequests, png };
} catch (e) {
  out = { ok: false, errors: [...errors, String(e && e.message || e)] };
} finally {
  try { ws && ws.close(); } catch (e) { /* 이미 닫힘 */ }
  chrome.kill("SIGTERM");
}
console.log(JSON.stringify(out));
process.exit(out.ok ? 0 : 1);
