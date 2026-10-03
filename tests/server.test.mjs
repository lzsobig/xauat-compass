import test from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {createApp} from '../server/index.mjs';
import {openStore,createTrial} from '../server/store.mjs';
import {DEFAULT_PROFILE} from '../shared/core.js';
const profile={...DEFAULT_PROFILE,interests:['code'],skills:['code']};
function modelBody(request){const user=JSON.parse(request.messages[1].content),id=user.candidates[0].id;return {summary:'从核验条件开始，完成四周准备练习。',recommendations:[{competitionId:id,role:'main',reason:'兴趣方向相关',gaps:['查阅要求'],pending:['核实当届资格']}],weeks:Array.from({length:4},(_,i)=>({week:i+1,tasks:[{competitionId:id,title:'核验资料并完成练习',hours:2}]}))};}
async function fixture(t,{mode='ok',limits={},delay=0}={}){
 let calls=0;const db=openStore(':memory:');const code=createTrial(db);
 const app=createApp({db,env:{ACCOUNTS_REQUIRED:'0',APP_ORIGIN:'http://compass.test',LLM_BASE_URL:mode==='unconfigured'?'':'https://model.invalid/v1',LLM_MODEL:'test-model',LLM_API_KEY:'test-secret',...limits},fetch:async(_url,opts)=>{
  calls++;if(delay)await new Promise((resolve,reject)=>{const timer=setTimeout(resolve,delay);opts.signal.addEventListener('abort',()=>{clearTimeout(timer);reject(new Error('aborted'));},{once:true});});
  let raw=modelBody(JSON.parse(opts.body));if(mode==='invalid-id')raw.recommendations[0].competitionId=99999;if(mode==='overbudget')raw.weeks[0].tasks[0].hours=100;
  if(mode==='http-error')return new Response('private upstream details',{status:429});
  return Response.json({choices:[{message:{content:mode==='invalid-json'?'bad-json':JSON.stringify(raw)}}],usage:{total_tokens:99}});
 }});
 app.server.listen(0,'127.0.0.1');await once(app.server,'listening');const base='http://127.0.0.1:'+app.server.address().port;
 t.after(async()=>{await new Promise(resolve=>app.server.close(resolve));db.close();});
 const post=(path,body,cookie,origin='http://compass.test')=>fetch(base+path,{method:'POST',headers:{'Content-Type':'application/json',Origin:origin,...(cookie?{Cookie:cookie}:{})},body:JSON.stringify(body)});
 const login=await post('/api/trial/session',{code});const cookie=login.headers.get('set-cookie').split(';')[0];
 return {db,base,post,cookie,code,get calls(){return calls;},generate:(id='request_0001',opts={})=>post('/api/plans/generate',{requestId:id,profile,...opts},cookie)};
}
test('anonymous capabilities and authenticated generation boundary',async t=>{const f=await fixture(t);const cap=await(await fetch(f.base+'/api/capabilities')).json();assert.equal(cap.authenticated,false);const res=await f.post('/api/plans/generate',{requestId:'request_x',profile});assert.equal(res.status,401);});
test('origin rejection and private files never exposed',async t=>{const f=await fixture(t);assert.equal((await f.post('/api/trial/session',{code:f.code},null,'https://evil.test')).status,403);for(const path of ['/.env','/runtime/compass.sqlite','/server/index.mjs','/package.json','/public/../../.env'])assert.equal((await fetch(f.base+path)).status,404);});
test('valid stream, deduplication and success quota persistence',async t=>{const f=await fixture(t,{limits:{TRIAL_DAILY_LIMIT:'1'}});const text=await(await f.generate()).text();const events=text.trim().split('\n').map(JSON.parse);assert.deepEqual(events.map(e=>e.type),['status','status','result']);assert.ok(!text.includes('test-secret'));assert.equal(f.calls,1);const replay=await(await f.generate()).text();assert.ok(replay.includes('"replayed":true'));assert.equal(f.calls,1);assert.equal((await f.generate('request_0002')).status,429);assert.equal(f.db.prepare("SELECT count(*) n FROM calls WHERE status='success'").get().n,1);});
for(const mode of ['invalid-json','invalid-id','overbudget','http-error'])test(`${mode} fails safely without consuming user quota`,async t=>{const f=await fixture(t,{mode});const text=await(await f.generate()).text();assert.ok(text.includes('"type":"error"'));assert.ok(!text.includes('"type":"result"'));assert.ok(!text.includes('private upstream'));assert.equal(f.db.prepare("SELECT count(*) n FROM calls WHERE status='success'").get().n,0);assert.equal(f.calls,1);});
test('failed upstream calls consume global limit',async t=>{const f=await fixture(t,{mode:'invalid-json',limits:{GLOBAL_DAILY_LIMIT:'1'}});await(await f.generate()).text();assert.equal((await f.generate('request_0002')).status,429);});
test('timeout is an error stream, not a successful plan',async t=>{const f=await fixture(t,{delay:100,limits:{LLM_TIMEOUT_MS:'15'}});const text=await(await f.generate()).text();assert.ok(text.includes('超时'));assert.equal(f.db.prepare("SELECT status FROM calls").get().status,'cancelled');});
test('concurrent requests for one trial are rejected',async t=>{const f=await fixture(t,{delay:100});const first=await f.generate();assert.equal((await f.generate('request_0002')).status,429);await first.text();});
test('cancelling client request releases trial without consuming success quota',async t=>{const f=await fixture(t,{delay:500});const controller=new AbortController();const response=await fetch(f.base+'/api/plans/generate',{method:'POST',headers:{Origin:'http://compass.test','Content-Type':'application/json',Cookie:f.cookie},body:JSON.stringify({requestId:'cancel_0001',profile}),signal:controller.signal});controller.abort();await response.text().catch(()=>{});await new Promise(r=>setTimeout(r,40));assert.equal(f.db.prepare('SELECT status FROM calls').get().status,'cancelled');});
test('unconfigured model returns clear failure while static app stays available',async t=>{const f=await fixture(t,{mode:'unconfigured'});assert.equal((await f.generate()).status,503);assert.equal((await fetch(f.base+'/')).status,200);assert.equal(f.calls,0);});
test('feedback requires session and confirms persisted result',async t=>{const f=await fixture(t);assert.equal((await f.post('/api/feedback',{kind:'feedback',useful:'yes'})).status,401);assert.equal((await f.post('/api/feedback',{kind:'feedback',useful:'yes',note:'需要更多对比'},f.cookie)).status,200);assert.equal(f.db.prepare('SELECT count(*) n FROM feedback').get().n,1);});
test('trial redemption is limited and cookies are HttpOnly',async t=>{const f=await fixture(t);const login=await f.post('/api/trial/session',{code:f.code});assert.match(login.headers.get('set-cookie'),/HttpOnly; (Secure; )?SameSite=Strict/);for(let i=0;i<8;i++)await f.post('/api/trial/session',{code:'bad'});assert.equal((await f.post('/api/trial/session',{code:'bad'})).status,429);});
