// Offline browser regression for discoverable layouts and folder architecture.
// Usage: node graph_structure_browser.mjs <chrome> <localized HTML directory> <temporary directory>
import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const [chromePath, htmlDirectory, temporaryDirectory] = process.argv.slice(2);
const port = 10600 + Math.floor(Math.random() * 400);
const chrome = spawn(chromePath, ["--headless=new", `--remote-debugging-port=${port}`,
  `--user-data-dir=${temporaryDirectory}/structure-chrome`, "--no-first-run", "--no-default-browser-check",
  "--disable-gpu", "--use-mock-keychain", "--password-store=basic", "about:blank"], { stdio: "ignore" });
const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
let socket, sequence = 0;
const pending = new Map(), errors = [], externalRequests = [], checks = [];
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = ++sequence;
  const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 30000);
  pending.set(id, (result) => {
    clearTimeout(timer);
    if (result.error) reject(new Error(JSON.stringify(result.error)));
    else resolve(result);
  });
  socket.send(JSON.stringify({ id, method, params }));
});
async function evaluate(expression) {
  const response = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (response.result.exceptionDetails) throw new Error(response.result.exceptionDetails.exception?.description || response.result.exceptionDetails.text);
  return response.result.result.value;
}
async function navigate(language) {
  await send("Page.navigate", { url: pathToFileURL(`${htmlDirectory}/${language}.html`).href + "#test" });
  for (let i = 0; i < 100; i++) {
    if (await evaluate(`!!window.gitchGraphTest && document.documentElement.lang === ${JSON.stringify(language)}`)) return;
    await sleep(50);
  }
  throw new Error(`Graph did not initialize in ${language}`);
}
async function check(name, expression) {
  const result = await evaluate(expression);
  checks.push({ name, ...result });
  if (!result?.ok) errors.push(`${name}: ${JSON.stringify(result)}`);
}
let output = { ok: false };
try {
  for (let i = 0; i < 100 && !socket; i++) {
    try {
      const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((entry) => entry.type === "page");
      if (page) {
        socket = new WebSocket(page.webSocketDebuggerUrl);
        await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
      }
    } catch { socket = undefined; }
    if (!socket) await sleep(100);
  }
  if (!socket) throw new Error("Chrome did not start");
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) { pending.get(message.id)(message); pending.delete(message.id); }
    else if (message.method === "Runtime.exceptionThrown") errors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
    else if (message.method === "Network.requestWillBeSent" && /^https?:/.test(message.params.request.url)) externalRequests.push(message.params.request.url);
  };
  await send("Runtime.enable");
  await send("Page.enable");
  await send("Network.enable");
  await send("Network.emulateNetworkConditions", { offline: true, latency: 0, downloadThroughput: 0, uploadThroughput: 0 });
  await send("Emulation.setDeviceMetricsOverride", { width: 1366, height: 900, deviceScaleFactor: 1, mobile: false });
  await navigate("en");
  await check("quick actions", `(async () => {
    const t=window.gitchGraphTest,$=id=>document.getElementById(id),wait=ms=>new Promise(r=>setTimeout(r,ms));
    const results=[];
    for(const relation of ['files','modules','changes','tree']) {
      document.querySelector('#tabs button[data-v="'+relation+'"]').click();
      $('quickStars').click();await wait(600);t.redraw();
      const before=t.state();$('quickNextStars').click();await wait(600);t.redraw();const after=t.state();
      results.push({relation,layout:after.layout,before:before.sky,after:after.sky,
        ok:after.rel===relation&&after.layout==='stars'&&!!before.sky&&!!after.sky&&before.sky!==after.sky});
    }
    $('quickFolders').click();const folder=t.state();
    $('quickArchitecture').click();
    const architecture=$('architectureTab').getAttribute('aria-selected')==='true'&&!$('architecture').hidden;
    $('quickLayouts').click();
    return {ok:results.every(r=>r.ok)&&folder.rel==='tree'&&folder.layout==='tidy'&&architecture&&$('gear').getAttribute('aria-selected')==='true',results,folder,architecture};
  })()`);
  await check("layout matrix", `(async () => {
    const t=window.gitchGraphTest,$=id=>document.getElementById(id),wait=ms=>new Promise(r=>setTimeout(r,ms)),results=[];
    const choose=(selector)=>{const e=document.querySelector(selector);if(!e)throw new Error('Missing '+selector);if(!e.classList.contains('on'))e.click();};
    for(const relation of ['files','modules','changes','tree']) {
      choose('#tabs button[data-v="'+relation+'"]');
      const layouts=relation==='tree'?['lanes']:['lanes','rings'];
      for(const style of ['dot','box']) for(const unit of relation==='files'||relation==='changes'?['file','folder']:['file']) {
        if(relation==='files'||relation==='changes')choose('#unit button[data-v="'+unit+'"]');
        choose('#style button[data-v="'+style+'"]');
        for(const layout of layouts) {
          choose('#layout button[data-v="'+layout+'"]');await wait(560);t.redraw();
          const s=t.state(),positions=t.capture().positions;
          results.push({relation,style,unit,layout,nodes:s.nodes,overlaps:t.overlaps(),ok:s.rel===relation&&s.layout===layout&&s.style===style&&s.nodes>0&&t.overlaps()===0&&positions.every(p=>p.slice(1,3).every(Number.isFinite))});
        }
      }
    }
    choose('#tabs button[data-v="files"]');choose('#unit button[data-v="file"]');
    const search=$('q'),only=$('onlyFound');
    for(const query of ['alpha/a.ts','not-present-structure-sentinel']) {
      search.value=query;search.dispatchEvent(new Event('input'));only.checked=true;only.dispatchEvent(new Event('change'));
      for(const layout of ['lanes','rings']) {
        choose('#layout button[data-v="'+layout+'"]');await wait(560);t.redraw();
        const s=t.state();results.push({query,layout,nodes:s.nodes,ok:s.nodes===(query==='alpha/a.ts'?1:0)&&t.overlaps()===0&&t.capture().positions.every(p=>p.slice(1,3).every(Number.isFinite))});
      }
    }
    search.value='';search.dispatchEvent(new Event('input'));only.checked=false;only.dispatchEvent(new Event('change'));
    return {ok:results.every(r=>r.ok),results};
  })()`);
  await check("architecture navigation and persistence", `(() => {
    const t=window.gitchGraphTest,$=id=>document.getElementById(id),change=(id,value)=>{$(id).value=value;$(id).dispatchEvent(new Event('change'));};
    $('quickArchitecture').click();change('architectureDepth','1');
    const initial=t.architecture(),rows=[...document.querySelectorAll('[data-architecture-group]')];
    const alphaMetrics=initial.groups.find(g=>g.id==='alpha'),betaMetrics=initial.groups.find(g=>g.id==='beta');
    const knownMetrics=alphaMetrics?.fileCount===3&&alphaMetrics.internalCount===3&&alphaMetrics.incomingCount===1&&alphaMetrics.outgoingCount===1&&alphaMetrics.internalShare===.75&&alphaMetrics.density===.5&&alphaMetrics.afferent===1&&alphaMetrics.efferent===1&&alphaMetrics.instability===.5&&
      betaMetrics?.fileCount===3&&betaMetrics.internalCount===2&&betaMetrics.incomingCount===1&&betaMetrics.outgoingCount===1&&betaMetrics.internalShare===2/3&&initial.cycles.some(c=>c.includes('alpha')&&c.includes('beta'));
    const alpha=rows.find(e=>e.dataset.architectureGroup==='alpha'),beta=rows.find(e=>e.dataset.architectureGroup==='beta');
    const pairs=[...document.querySelectorAll('[data-architecture-pair]')],pair=pairs.find(e=>e.textContent.includes('alpha')&&e.textContent.includes('beta'));
    if(!alpha||!beta||!pair)return {ok:false,reason:'Missing alpha/beta groups or cross-folder pair',initial,rows:rows.map(e=>e.dataset.architectureGroup)};
    alpha.click();const groupPane=$('architectureTab').getAttribute('aria-selected')==='true'&&!$('architecture').hidden,groupHighlight=t.highlight();
    const groupFocused=JSON.stringify(groupHighlight.nodes.slice().sort())===JSON.stringify(['alpha/a.ts','alpha/b.ts','alpha/nested/e.ts','beta/c.ts'])&&groupHighlight.edges===5;
    [...document.querySelectorAll('[data-architecture-pair]')].find(e=>e.dataset.architecturePair===JSON.stringify(['alpha','beta'])).click();
    const pairPane=$('architectureTab').getAttribute('aria-selected')==='true'&&!$('architecture').hidden,pairHighlight=t.highlight();
    const pairFocused=JSON.stringify(pairHighlight.nodes.slice().sort())===JSON.stringify(['alpha/a.ts','beta/c.ts'])&&pairHighlight.edges===1;
    const search=$('architectureSearch');search.value='alpha';search.dispatchEvent(new Event('input'));
    const filteredRows=[...document.querySelectorAll('[data-architecture-group]')];
    const filtered=filteredRows.length>0&&filteredRows.every(e=>e.textContent.toLowerCase().includes('alpha'));
    search.value='';search.dispatchEvent(new Event('input'));
    const sort=$('architectureSort'),sorting=[];
    for(const option of sort.options){
      sort.value=option.value;sort.dispatchEvent(new Event('change'));
      const order=[...document.querySelectorAll('[data-architecture-group]')].map(e=>e.dataset.architectureGroup);
      sorting.push(order.length===initial.groups.length&&(option.value!=='name'||JSON.stringify(order)===JSON.stringify(order.slice().sort()))&&(option.value!=='share'||order.indexOf('beta')<order.indexOf('alpha')));
    }
    const inferred=$('architectureInferred');inferred.checked=true;inferred.dispatchEvent(new Event('change'));const withInferred=t.architecture();
    inferred.checked=false;inferred.dispatchEvent(new Event('change'));const withoutInferred=t.architecture();
    change('architectureDepth','2');const nested=[...document.querySelectorAll('[data-architecture-group]')].some(e=>e.dataset.architectureGroup==='alpha/nested');
    $('quickLayouts').click();document.querySelector('#layout button[data-v="lanes"]').click();$('quickArchitecture').click();
    const captured=t.capture();$('quickFolders').click();$('quickLayouts').click();t.restore(captured);
    const restored=t.capture(),persisted=t.state().layout==='lanes'&&$('architectureTab').getAttribute('aria-selected')==='true'&&$('architectureDepth').value==='2';
    const inferredCounts=withInferred.totals.dependencies===withoutInferred.totals.dependencies+1&&withInferred.totals.inferred===1&&withoutInferred.totals.inferred===0;
    const summary=data=>({totals:data.totals,cycles:data.cycles,groups:data.groups.map(g=>({id:g.id,files:g.fileCount,internal:g.internalCount,incoming:g.incomingCount,outgoing:g.outgoingCount,share:g.internalShare}))});
    return {ok:knownMetrics&&groupPane&&groupFocused&&pairPane&&pairFocused&&filtered&&sorting.every(Boolean)&&nested&&persisted&&inferredCounts,knownMetrics,groupPane,groupFocused,pairPane,pairFocused,groupHighlight,pairHighlight,filtered,nested,persisted,inferredCounts,initial:summary(initial),withInferred:withInferred.totals,withoutInferred:withoutInferred.totals,panels:restored.panels};
  })()`);
  await evaluate(`(() => {
    document.getElementById('quickArchitecture').click();
    const depth=document.getElementById('architectureDepth');depth.value='1';depth.dispatchEvent(new Event('change'));
    [...document.querySelectorAll('[data-architecture-group]')].find(e=>e.dataset.architectureGroup==='alpha').focus();
  })()`);
  await send("Input.dispatchKeyEvent", { type: "keyDown", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 });
  await send("Input.dispatchKeyEvent", { type: "keyUp", key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13 });
  await check("architecture keyboard focus", `(() => {
    const focused=document.activeElement,group=focused?.dataset.architectureGroup;
    return {ok:group==='alpha'&&document.getElementById('architectureTab').getAttribute('aria-selected')==='true',group,element:focused?.tagName};
  })()`);
  await check("architecture folder scope", `(() => {
    const t=window.gitchGraphTest,$=id=>document.getElementById(id);
    $('foldersNav').click();
    [...document.querySelectorAll('#folders .folder-scope')].find(e=>e.dataset.folder==='alpha/').click();
    const scoped=t.architecture(),rows=[...document.querySelectorAll('[data-architecture-group]')].map(e=>e.dataset.architectureGroup);
    const limited=scoped.totals.files===3&&scoped.totals.dependencies===3&&scoped.totals.boundary===0&&rows.length===1&&rows[0]==='alpha'&&$('architectureScope').textContent.includes('alpha');
    document.querySelector('#folderScope button[data-folder=""]').click();const restored=t.architecture();
    return {ok:limited&&restored.totals.files===12&&restored.totals.boundary===2,limited,scoped:scoped.totals,restored:restored.totals};
  })()`);
  await check("constellation saved shape", `(async () => {
    const t=window.gitchGraphTest,$=id=>document.getElementById(id),wait=ms=>new Promise(r=>setTimeout(r,ms));
    document.querySelector('#tabs button[data-v="modules"]').click();$('quickStars').click();await wait(560);t.redraw();
    const captured=t.capture(),before=t.state().sky;
    $('quickNextStars').click();await wait(560);t.redraw();const next=t.state().sky;
    t.restore(captured);await wait(560);t.redraw();const restored=t.state().sky;
    return {ok:!!before&&before!==next&&restored===before&&t.state().rel==='modules'&&t.state().layout==='stars',before,next,restored};
  })()`);
  for (const language of ["en", "ko", "ja"]) {
    await navigate(language);
    await check(`localized layout labels (${language})`, `(() => {
      const $=id=>document.getElementById(id),labels={en:['Constellation','Folder lanes','Dependency rings'],ko:['별자리','폴더별 행','의존성 링'],ja:['星座','フォルダー別レーン','依存関係リング']}[${JSON.stringify(language)}];
      $('quickLayouts').click();const text=$('layout').textContent;
      const buttons=[...$('layout').querySelectorAll('button[data-v]')];
      return {ok:document.documentElement.lang===${JSON.stringify(language)}&&buttons.length>=7&&labels.every(label=>text.includes(label))&&buttons.every(b=>!!b.getAttribute('title')||b.textContent.trim().length>0),labels:buttons.map(b=>b.textContent.trim())};
    })()`);
    for (const [width, height] of [[1366,900],[1000,800],[900,600],[680,800],[390,844],[390,600],[680,500]]) {
      await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
      await sleep(100);
      for (const action of ["quickLayouts", "quickArchitecture"]) {
        await check(`responsive ${language} ${width}x${height} ${action}`, `(() => {
          const $=id=>document.getElementById(id);$('${action}').click();
          const visible=e=>!!e&&!e.hidden&&e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden';
          const ids=['quickStars','quickFolders','quickArchitecture','quickLayouts'];
          const rectangles=ids.map(id=>{const e=$(id),r=e.getBoundingClientRect();return {id,visible:!!visible(e),x:r.left,y:r.top,right:r.right,bottom:r.bottom,w:r.width,h:r.height};});
          const inside=rectangles.every(r=>r.visible&&r.w>=28&&r.h>=28&&r.x>=-1&&r.y>=-1&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1);
          const overlaps=rectangles.some((a,i)=>rectangles.slice(i+1).some(b=>Math.min(a.right,b.right)-Math.max(a.x,b.x)>1&&Math.min(a.bottom,b.bottom)-Math.max(a.y,b.y)>1));
          const panes=['top','rightDock'].map(id=>$(id)).filter(visible).map(e=>({id:e.id,r:e.getBoundingClientRect()}));
          const covered=rectangles.some(a=>panes.some(({r})=>Math.min(a.right,r.right)-Math.max(a.x,r.left)>1&&Math.min(a.bottom,r.bottom)-Math.max(a.y,r.top)>1));
          const viewport=window.gitchGraphTest.state().viewport;
          let architecture={ok:true};
          if('${action}'==='quickArchitecture') {
            const body=$('architectureBody'),scroller=getComputedStyle(body).overflowY==='visible'?$('architecture'):body,last=body.querySelector('[data-architecture-group]:last-child'),scroll=scroller.scrollTop;
            last?.scrollIntoView({block:'nearest'});
            const br=scroller.getBoundingClientRect(),lr=last?.getBoundingClientRect(),shown=lr?Math.min(br.bottom,lr.bottom,innerHeight)-Math.max(br.top,lr.top,0):0;
            architecture={ok:scroller.clientHeight>60&&!!last&&shown>16,height:scroller.clientHeight,visibleRow:shown,scrollable:scroller.scrollHeight>scroller.clientHeight};
            scroller.scrollTop=scroll;
          }
          let cards={ok:true};
          if('${action}'==='quickLayouts') {
            const layout=$('layout'),columns=getComputedStyle(layout).gridTemplateColumns.trim().split(' ').filter(Boolean).length;
            const sizes=[...layout.querySelectorAll('button[data-v]')].map(e=>{const r=e.getBoundingClientRect();return {w:r.width,h:r.height};});
            cards={ok:columns===2&&sizes.length>=7&&sizes.every(s=>s.w>=110&&s.h>=32&&s.h<70),columns,sizes};
          }
          return {ok:inside&&!overlaps&&!covered&&document.documentElement.scrollWidth<=innerWidth+1&&viewport.r>viewport.l&&viewport.b>viewport.t&&architecture.ok&&cards.ok,inside,overlaps,covered,architecture,cards,viewport,rectangles};
        })()`);
      }
    }
  }
  if (process.env.GITCH_STRUCTURE_SCREENSHOT_DIR) {
    const screenshotDirectory=process.env.GITCH_STRUCTURE_SCREENSHOT_DIR;
    await mkdir(screenshotDirectory,{recursive:true});
    await send("Emulation.setDeviceMetricsOverride",{width:1366,height:900,deviceScaleFactor:1,mobile:false});
    await navigate("ko");
    for(const theme of ["dark","light"]) {
      await evaluate(`(() => {
        if(document.documentElement.dataset.theme!==${JSON.stringify(theme)})document.getElementById('theme').click();
        document.getElementById('foldersNav').click();
      })()`);
      for(const layout of ["stars","lanes","architecture"]) {
        await evaluate(`(() => {
          const t=window.gitchGraphTest,$=id=>document.getElementById(id);
          if(${JSON.stringify(layout)}==='architecture') {
            $('quickArchitecture').click();$('architectureDepth').value='1';$('architectureDepth').dispatchEvent(new Event('change'));
          } else {
            $('quickLayouts').click();document.querySelector('#layout button[data-v="'+${JSON.stringify(layout)}+'"]').click();
          }
          t.redraw();
        })()`);
        await sleep(600);
        await evaluate("window.gitchGraphTest.redraw()");
        const image=await send("Page.captureScreenshot",{format:"png"});
        await writeFile(`${screenshotDirectory}/${layout}-${theme}-1366.png`,Buffer.from(image.result.data,"base64"));
      }
    }
    await send("Emulation.setDeviceMetricsOverride",{width:390,height:600,deviceScaleFactor:1,mobile:false});
    for(const theme of ["dark","light"]) {
      await evaluate(`(() => {
        if(document.documentElement.dataset.theme!==${JSON.stringify(theme)})document.getElementById('theme').click();
        document.getElementById('quickArchitecture').click();
        document.querySelector('[data-architecture-group="alpha"]')?.scrollIntoView({block:'center'});
        window.gitchGraphTest.redraw();
      })()`);
      await sleep(100);
      const image=await send("Page.captureScreenshot",{format:"png"});
      await writeFile(`${screenshotDirectory}/architecture-${theme}-390x600.png`,Buffer.from(image.result.data,"base64"));
    }
  }
  const screenshot = await send("Page.captureScreenshot", { format: "png" });
  await writeFile(`${temporaryDirectory}/graph-structure.png`, Buffer.from(screenshot.result.data, "base64"));
  if (process.env.GITCH_TEST_ARTIFACT_DIR) {
    await mkdir(process.env.GITCH_TEST_ARTIFACT_DIR, { recursive: true });
    await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-structure.png`, Buffer.from(screenshot.result.data, "base64"));
    await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-structure.html`, await readFile(`${htmlDirectory}/ja.html`));
  }
  output = { ok: !errors.length && !externalRequests.length, errors, externalRequests,
    checks: checks.map((result) => result.ok ? { name: result.name, ok: true, cases: result.results?.length } : result) };
} catch (error) {
  output = { ok: false, errors: [...errors, String(error.message || error)], checks };
} finally {
  try { socket?.close(); } catch {}
  chrome.kill("SIGTERM");
}
console.log(JSON.stringify(output));
process.exit(output.ok ? 0 : 1);
