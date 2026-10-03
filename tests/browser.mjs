import {chromium} from 'playwright';
import assert from 'node:assert/strict';
import {mkdirSync,writeFileSync,copyFileSync,existsSync,readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {once} from 'node:events';
import {createApp} from '../server/index.mjs';
import {openStore,createTrial} from '../server/store.mjs';

const out=resolve('output/playwright');mkdirSync(out,{recursive:true});
const base=process.env.TEST_URL||'http://127.0.0.1:4173';
const report={checks:[],errors:[],overflow:[],performance:{},note:'AI UI tests use an explicitly mocked upstream; no live model validation is claimed.'};
const browser=await chromium.launch({channel:process.env.BROWSER_CHANNEL||'chrome',headless:true});
const video=process.env.RECORD_VIDEO==='1';
const context=await browser.newContext({viewport:{width:1440,height:1000},locale:'zh-CN',...(video?{recordVideo:{dir:out,size:{width:1440,height:1000}}}:{})});
const page=await context.newPage();page.on('pageerror',e=>report.errors.push(e.message));
const check=(name,condition=true)=>{assert.ok(condition,name);report.checks.push(name);};
const settle=()=>page.waitForTimeout(700);
const shot=async name=>{await settle();await page.screenshot({path:resolve(out,name+'.png'),fullPage:false});};
async function click(action){await page.locator(`#page [data-action="${action}"]`).first().click();}
async function navigate(route){await page.locator(`.sidebar [data-route="${route}"],.mobile-nav [data-route="${route}"]`).filter({visible:true}).first().click();await settle();}
async function close(){await page.locator('#sheet [data-action="close-sheet"]').click();await page.waitForFunction(()=>!document.querySelector('#sheet').open);}
async function assertFits(label){const size=await page.evaluate(()=>({w:innerWidth,scroll:document.documentElement.scrollWidth}));report.overflow.push({label,...size});check('no overflow: '+label,size.scroll<=size.w+1);}

try{
 await page.goto(base);await page.locator('.hero').waitFor();await shot('home-desktop');check('home starts with empty local task plan',await page.locator('.home-stat').last().innerText().then(t=>t.includes('00')));
 const cdp=await context.newCDPSession(page);await cdp.send('DOM.enable');await cdp.send('CSS.enable');const doc=await cdp.send('DOM.getDocument');const titleNode=await cdp.send('DOM.querySelector',{nodeId:doc.root.nodeId,selector:'.hero h1'});report.fonts=await cdp.send('CSS.getPlatformFontsForNode',{nodeId:titleNode.nodeId});
 await navigate('discover');await shot('discover-desktop');check('catalog rows render',await page.locator('.catalog-row').count()===18);
 await page.locator('#search').fill('数学建模');await page.waitForTimeout(250);check('search filters real records',(await page.locator('.catalog-row').count())>0);await page.locator('#search').fill('');await page.waitForTimeout(250);
 await page.locator('.catalog-row [data-action="compare"]').nth(0).click();await page.locator('.catalog-row [data-action="compare"]').nth(1).click();await page.locator('.catalog-row [data-action="compare"]').nth(2).click();await page.locator('.catalog-row [data-action="compare"]').nth(3).click();check('comparison limited to three',await page.locator('.compare-bar').innerText().then(t=>t.includes('3 / 3')));
 await page.locator('[data-action="show-compare"]').click();await shot('comparison-desktop');check('three comparison columns',await page.locator('.compare-cell').count()===3);await close();
 await page.locator('[data-action="clear-compare"]').click();await page.locator('.catalog-open').first().click();await shot('detail-desktop');await page.keyboard.press('Escape');await page.waitForFunction(()=>!document.querySelector('#sheet').open);check('detail restores focus',await page.evaluate(()=>document.activeElement.classList.contains('catalog-open')));
 await navigate('plan');await shot('planning-desktop');await click('next-step');await page.locator('[data-action="interest-pick"][data-value="code"]').click();await page.locator('[data-action="skill-pick"][data-value="code"]').click();await click('next-step');await page.locator('#profile-hours').fill('3');await click('next-step');await click('generate-basic');await page.locator('.result-grid').waitFor();await shot('result-desktop');check('base plan explicitly labelled',await page.locator('.plan-intro').innerText().then(t=>t.includes('非模型生成')));check('four weeks rendered',await page.locator('.week-card').count()===4);
 await click('save-plan');await click('save-plan');await navigate('tasks');check('plan save idempotent',await page.locator('.task-row').count()===4);await page.locator('.check-task').first().click();check('task completion applied',await page.locator('.task-row.done').count()===1);await page.locator('#toast [data-action="undo"]').click();check('task completion undo',await page.locator('.task-row.done').count()===0);await shot('tasks-desktop');
 await page.locator('[data-action="edit-task"]').first().click();await page.locator('#task-due').fill('2026-11-30');await page.locator('#task-form [type="submit"]').click();await page.waitForFunction(()=>!document.querySelector('#sheet').open);
 const [backup]=await Promise.all([page.waitForEvent('download'),click('backup')]);await backup.saveAs(resolve(out,'test-backup.json'));
 const [ics]=await Promise.all([page.waitForEvent('download'),click('calendar')]);await ics.saveAs(resolve(out,'test-calendar.ics'));check('calendar exported with real user date',readFileSync(resolve(out,'test-calendar.ics'),'utf8').includes('20261130'));
 await page.locator('#restore-file').setInputFiles(resolve(out,'test-backup.json'));await settle();check('restore merges without duplicating',await page.locator('.task-row').count()===4);
 await page.reload();await settle();check('tasks persist across reload',await page.locator('.task-row').count()===4);
 await navigate('rules');await page.locator('#credit-form [name="confirmed"]').check();await page.locator('#credit-form [type="submit"]').click();check('known estimate shows reference',await page.locator('#credit-result').innerText().then(t=>t.includes('参考学分')));await page.locator('#credit-college').selectOption('其他学院');await page.locator('#credit-form [type="submit"]').click();check('unsupported college not silently calculated',await page.locator('#credit-result').innerText().then(t=>t.includes('暂不能核算')));await shot('rules-desktop');
 for(const width of [375,768,1024,1440]){
  await page.setViewportSize({width,height:900});
  for(const route of ['home','discover','plan','tasks','rules']){
   await page.goto(base+'/#'+route);await settle();await assertFits(`${width}/${route}`);
   if(width===375||width===768)await page.screenshot({path:resolve(out,`${route}-${width}.png`)});
  }
 }
 await page.setViewportSize({width:375,height:812});await page.goto(base+'/#discover');await settle();await page.locator('.catalog-open').first().click();await shot('detail-mobile');await close();check('mobile sheet unlocks body',await page.evaluate(()=>getComputedStyle(document.body).overflow!=='hidden'));
 await page.locator('[data-action="filters"]').click();await page.locator('#sheet #filter-tier').selectOption('一类A1');await page.locator('[data-action="apply-filters"]').click();await settle();check('mobile filters apply',await page.locator('.catalog-row').count()>0);await assertFits('375/mobile-filtered');
 await page.goto(base+'/#plan');await settle();await click('next-step');await click('next-step');await click('next-step');await click('generate-basic');await settle();await assertFits('375/result');await shot('result-mobile');
 await page.emulateMedia({reducedMotion:'reduce'});await page.goto(base);await settle();check('reduced motion stops decorative animations',await page.locator('.hero').evaluate(el=>el.getAnimations({subtree:true}).length===0));await shot('home-reduced-motion');
 await page.emulateMedia({reducedMotion:'no-preference'});await page.setViewportSize({width:1440,height:1000});await cdp.send('Emulation.setCPUThrottlingRate',{rate:4});await page.goto(base+'/#discover');await settle();
 report.performance=await page.evaluate(async()=>{const gaps=[];let previous=performance.now();await new Promise(resolve=>{let n=0;const frame=t=>{gaps.push(t-previous);previous=t;if(++n<60)requestAnimationFrame(frame);else resolve();};requestAnimationFrame(frame);document.querySelector('.catalog-open').click();});gaps.sort((a,b)=>a-b);return {cpuThrottle:4,frames:gaps.length,medianFrameMs:gaps[Math.floor(gaps.length/2)],p95FrameMs:gaps[Math.floor(gaps.length*.95)],maxFrameMs:Math.max(...gaps)};});await close();await cdp.send('Emulation.setCPUThrottlingRate',{rate:1});
 for(let i=0;i<6;i++){await page.locator('.catalog-open').first().click();await page.keyboard.press('Escape');await page.waitForFunction(()=>!document.querySelector('#sheet').open);}
 check('repeated sheet cycles leave no scroll lock',await page.evaluate(()=>!document.querySelector('#sheet').open&&document.body.style.overflow===''));
 const offlinePage=await context.newPage();offlinePage.on('pageerror',e=>report.errors.push('offline: '+e.message));await offlinePage.goto('file:///'+resolve('dist/建大竞赛罗盘_离线版.html').replaceAll('\\','/'));await offlinePage.locator('.hero').waitFor();check('offline standalone loads');await offlinePage.close();
 // Exercise the exact production endpoint with an explicitly simulated model transport.
 const testDB=openStore(':memory:'),code=createTrial(testDB);const aiOrigin='http://127.0.0.1:4184';
 const mock=createApp({db:testDB,env:{APP_ORIGIN:aiOrigin,LLM_BASE_URL:'https://test.invalid/v1',LLM_MODEL:'fixture',LLM_API_KEY:'fixture'},fetch:async(_url,opts)=>{await new Promise(r=>setTimeout(r,1100));const content=JSON.parse(JSON.parse(opts.body).messages[1].content);const id=content.candidates[0].id;return Response.json({choices:[{message:{content:JSON.stringify({summary:'测试夹具：验证智能规划接口与界面完整流程。',recommendations:[{competitionId:id,role:'main',reason:'测试数据与所选方向关联。',gaps:['核对当届要求'],pending:['当届日期未核验']}],weeks:[1,2,3,4].map(week=>({week,tasks:[{competitionId:id,title:'测试夹具准备任务 '+week,hours:2}]}))})}}],usage:{total_tokens:250}});}});
 mock.server.listen(4184,'127.0.0.1');await once(mock.server,'listening');
 try{
  await page.goto(aiOrigin+'/#plan');await settle();await page.locator('[data-action="trial"]').first().click();await page.locator('#trial-code').fill(code);await page.locator('#trial-form [type="submit"]').click();await page.waitForFunction(()=>!document.querySelector('#sheet').open);await click('next-step');await page.locator('[data-action="interest-pick"][data-value="code"]').click();await click('next-step');await click('next-step');await click('generate-ai');await page.locator('.generation-panel').waitFor();await page.screenshot({path:resolve(out,'generation-mock.png')});await page.locator('.result-grid').waitFor();await shot('ai-result-mock');check('mock AI endpoint completes actual UI flow',await page.locator('.plan-intro').innerText().then(t=>t.includes('智能规划')));
  await click('save-plan');await page.locator('#page [data-action="feedback"]').click();await page.locator('#feedback-note').fill('浏览器验收测试');await page.locator('#feedback-form [type="submit"]').click();await page.waitForFunction(()=>!document.querySelector('#sheet').open);check('feedback truly persisted',testDB.prepare("SELECT count(*) n FROM feedback WHERE kind='feedback'").get().n===1);
 }finally{await new Promise(r=>mock.server.close(r));testDB.close();}
 check('no browser JS errors',report.errors.length===0);
}catch(error){report.failure=error.stack;throw error;}
finally{
 await context.close();if(video){const path=await page.video().path();copyFileSync(path,resolve(out,'interaction-desktop.webm'));}
 await browser.close();writeFileSync(resolve(out,'browser-report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({checks:report.checks.length,errors:report.errors,failure:report.failure,performance:report.performance},null,2));
}
