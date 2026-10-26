// Real-browser regression for snapshot replay, independent of graph_browser.mjs.
// Usage: node graph_replay_browser.mjs <chrome> <diff html> <temporary directory>
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const [chromePath, html, tmp] = process.argv.slice(2);
const port = 9900 + Math.floor(Math.random() * 400);
const chrome = spawn(chromePath, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${tmp}/replay-chrome`, '--no-first-run', '--no-default-browser-check', '--disable-gpu', '--use-mock-keychain', '--password-store=basic', 'about:blank'], { stdio:'ignore' });
const sleep = ms => new Promise(resolve=>setTimeout(resolve,ms));
let ws, sequence=0;
const pending=new Map(), errors=[], externalRequests=[];
const send=(method,params={})=>new Promise((resolve,reject)=>{
  const id=++sequence;
  const timer=setTimeout(()=>{pending.delete(id);reject(new Error('CDP timeout: '+method));},15000);
  pending.set(id,result=>{clearTimeout(timer);result.error?reject(new Error(JSON.stringify(result.error))):resolve(result);});
  ws.send(JSON.stringify({id,method,params}));
});
async function evaluate(expression) {
  const response=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});
  if(response.result.exceptionDetails)throw new Error(response.result.exceptionDetails.exception?.description||response.result.exceptionDetails.text);
  return response.result.result.value;
}
let out={ok:false};
try {
  for(let i=0;i<100&&!ws;i++) {
    try {
      const page=(await(await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find(p=>p.type==='page');
      if(page){ws=new WebSocket(page.webSocketDebuggerUrl);await new Promise((resolve,reject)=>{ws.onopen=resolve;ws.onerror=reject;});}
    } catch {ws=undefined;}
    if(!ws)await sleep(100);
  }
  if(!ws)throw new Error('Chrome did not start');
  ws.onmessage=event=>{
    const message=JSON.parse(event.data);
    if(message.id&&pending.has(message.id)){pending.get(message.id)(message);pending.delete(message.id);}
    else if(message.method==='Runtime.exceptionThrown')errors.push(message.params.exceptionDetails.exception?.description||message.params.exceptionDetails.text);
    else if(message.method==='Network.requestWillBeSent'&&/^https?:/.test(message.params.request.url))externalRequests.push(message.params.request.url);
  };
  await send('Runtime.enable');await send('Page.enable');await send('Network.enable');
  await send('Network.emulateNetworkConditions',{offline:true,latency:0,downloadThroughput:0,uploadThroughput:0});
  // 실행 기기의 접근성 설정은 재생 검사와 분리하고 마지막에 reduce를 따로 검증한다.
  await send('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'no-preference'}]});
  await send('Emulation.setDeviceMetricsOverride',{width:1366,height:900,deviceScaleFactor:1,mobile:false});
  await send('Page.navigate',{url:pathToFileURL(html).href+'#test'});
  await send('Page.bringToFront');
  for(let i=0;i<100;i++){if(await evaluate('!!window.gitchGraphTest'))break;await sleep(100);}
  const results=await evaluate(`(async()=>{
    const t=window.gitchGraphTest,$=id=>document.getElementById(id),wait=ms=>new Promise(r=>setTimeout(r,ms));
    const assert=(value,message)=>{if(!value)throw new Error(message);};
    // CI 부하로 프레임이 늦어져도 실제 상태 전환을 기다리되 정지는 제한 시간 안에 실패시킨다.
    const waitFor=async(predicate,message)=>{const end=performance.now()+3000;while(!predicate()&&performance.now()<end)await wait(25);assert(predicate(),message);};
    const seek=value=>{$('replayRange').value=String(value);$('replayRange').dispatchEvent(new Event('input'));t.redraw();return t.replay();};
    assert(!$('replay').hidden,'replay controls missing on diff');
    t.select('src/same.ts');const old=t.capture();$('replayOpen').click();
    const before=seek(0),node=(s,id)=>s.nodes.find(n=>n.id===id),edge=(s,target)=>s.edges.find(e=>e.source==='src/entry.ts'&&e.target===target);
    assert(before.active&&!before.playing&&node(before,'src/gone.ts').opacity===1&&node(before,'src/new.ts').opacity===0,'incorrect baseline node membership');
    assert(node(before,'src/moved.ts').before&&node(before,'src/moved.ts').current&&node(before,'src/moved.ts').label==='old.ts','rename identity lost');
    assert(edge(before,'src/gone.ts').opacity===1&&edge(before,'src/new.ts').opacity===0,'incorrect baseline edge membership');
    const baselineImage=$('c').toDataURL();
    const middle=seek(500);
    assert(node(middle,'src/gone.ts').opacity>0&&node(middle,'src/gone.ts').opacity<1&&node(middle,'src/new.ts').opacity>0&&node(middle,'src/new.ts').opacity<1,'scrubbing does not interpolate');
    assert(node(middle,'src/moved.ts').label.includes('→'),'rename transition label missing');
    assert(before.nodes.every(n=>{const p=node(middle,n.id);return n.x===p.x&&n.y===p.y;}),'replay moves fixed node positions');
    const current=seek(1000);
    assert(node(current,'src/gone.ts').opacity===0&&node(current,'src/new.ts').opacity===1,'incorrect current node membership');
    assert(edge(current,'src/gone.ts').opacity===0&&edge(current,'src/new.ts').opacity===1,'incorrect current edge membership');
    assert(node(current,'src/moved.ts').label==='moved.ts','current rename label incorrect');
    assert(baselineImage!==$('c').toDataURL(),'canvas did not change');
    seek(0);$('replayPlay').click();await waitFor(()=>t.replay().progress>0&&t.replay().playing,'play did not advance');
    $('replayPlay').click();const paused=t.replay().progress;await wait(120);assert(t.replay().progress===paused,'pause did not stop');
    $('replaySpeed').value='2';$('replaySpeed').dispatchEvent(new Event('change'));
    $('replayLoop').checked=true;$('replayLoop').dispatchEvent(new Event('change'));seek(990);$('replayPlay').click();
    await waitFor(()=>t.replay().playing&&t.replay().progress<.5,'repeat did not restart');
    $('replayLoop').checked=false;$('replayLoop').dispatchEvent(new Event('change'));seek(990);$('replayPlay').click();
    await waitFor(()=>!t.replay().playing&&t.replay().progress===1,'play did not stop at current snapshot');
    seek(0);t.select('src/new.ts');assert(t.replay().progress===1&&t.capture().selected==='src/new.ts','search/select cannot reveal future node');
    $('q').value='src/old.ts';$('q').dispatchEvent(new Event('input'));assert($('searchResults').textContent.includes('moved.ts'),'old rename path is not searchable');
    $('q').value='src/new.ts';$('q').dispatchEvent(new Event('input'));
    $('onlyFound').checked=true;$('onlyFound').dispatchEvent(new Event('change'));
    assert(t.replay().active&&!t.replay().playing&&t.replay().nodes.length===1&&t.replay().nodes[0].id==='src/new.ts','search filter diverges from replay');
    $('q').value='';$('q').dispatchEvent(new Event('input'));$('onlyFound').checked=false;$('onlyFound').dispatchEvent(new Event('change'));
    $('lang').value='python';$('lang').dispatchEvent(new Event('change'));
    assert(t.replay().nodes.length>0&&t.visible().every(n=>n.langs.includes('python')),'language filter diverges from replay');
    $('lang').value='all';$('lang').dispatchEvent(new Event('change'));
    $('heur').checked=false;$('heur').dispatchEvent(new Event('change'));
    assert(!t.replay().edges.some(e=>e.kind==='type-ref'&&e.opacity>0),'heuristic filter ignored');
    $('heur').checked=true;$('heur').dispatchEvent(new Event('change'));
    $('replayClose').click();const restored=t.capture();
    assert(!t.replay().active&&t.state().layout===old.display.files.layout&&t.state().unit===old.display.files.unit&&restored.selected===old.selected&&JSON.stringify(restored.camera)===JSON.stringify(old.camera)&&JSON.stringify(restored.positions)===JSON.stringify(old.positions),'close did not restore display/camera/selection/positions');
    document.querySelector('#tabs button[data-v="modules"]').click();assert(!$('replay').hidden,'module replay unavailable');$('replayOpen').click();seek(0);
    assert(t.replay().active&&t.replay().nodes.some(n=>n.before&&!n.current),'module removed dependency missing');seek(1000);
    assert(t.replay().nodes.some(n=>!n.before&&n.current&&n.opacity===1),'module added dependency missing');
    document.querySelector('#tabs button[data-v="tree"]').click();assert(!t.replay().active&&$('replay').hidden,'tab switch did not exit replay');
    document.querySelector('#tabs button[data-v="files"]').click();
    $('replayOpen').click();seek(500);
    return {endpoints:true,interpolation:true,fixedPositions:true,renames:true,playPause:true,repeat:true,filters:true,modules:true,restore:true,beforeNodes:before.nodes.filter(n=>n.opacity>0).length,currentNodes:current.nodes.filter(n=>n.opacity>0).length};
  })()`);
  const shot=await send('Page.captureScreenshot',{format:'png'});
  await writeFile(`${tmp}/graph-replay.png`,Buffer.from(shot.result.data,'base64'));
  if(process.env.GITCH_TEST_ARTIFACT_DIR) {
    await mkdir(process.env.GITCH_TEST_ARTIFACT_DIR,{recursive:true});
    await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-replay.png`,Buffer.from(shot.result.data,'base64'));
    await writeFile(`${process.env.GITCH_TEST_ARTIFACT_DIR}/graph-replay.html`,await readFile(html));
  }
  await send('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]});
  await sleep(100);
  const reduced=await evaluate(`(()=>{const t=window.gitchGraphTest;document.getElementById('replayClose').click();document.getElementById('replayOpen').click();return t.replay().reduced&&!t.replay().playing&&document.getElementById('replayPlay').disabled;})()`);
  if(!reduced)throw new Error('reduced-motion preference ignored');
  out={ok:!errors.length&&!externalRequests.length&&reduced,errors,externalRequests,reduced,results,screenshot:`${tmp}/graph-replay.png`};
} catch(error) {out={ok:false,errors:[...errors,String(error.message||error)]};}
finally {try{ws?.close();}catch{}chrome.kill('SIGTERM');}
console.log(JSON.stringify(out));process.exit(out.ok?0:1);
