import test from 'node:test';
import assert from 'node:assert/strict';
import {openStore,createTrial} from '../server/store.mjs';
import {sqliteAdapter} from '../cloudflare/sqlite-adapter.js';
import {handleApi} from '../cloudflare/worker.mjs';
import {DEFAULT_PROFILE} from '../shared/core.js';

function fixture(){
  const sqlite=openStore(':memory:'),code=createTrial(sqlite);
  const storage={sql:{exec(query,...values){const stmt=sqlite.prepare(query);let rows;if(stmt.columns().length)rows=stmt.all(...values);else{stmt.run(...values);rows=[];}return {toArray:()=>rows};}},transactionSync(fn){sqlite.exec('BEGIN');try{const result=fn();sqlite.exec('COMMIT');return result;}catch(error){sqlite.exec('ROLLBACK');throw error;}}};
  const env={DB:sqliteAdapter(storage),ACCOUNTS_REQUIRED:'0',APP_ORIGIN:'https://compass.lzso.top',LLM_BASE_URL:'https://fixture.invalid/v1',LLM_MODEL:'fixture',LLM_API_KEY:'fixture-secret',TRIAL_DAILY_LIMIT:'1',GLOBAL_DAILY_LIMIT:'3',MAX_CONCURRENT:'2'};
  const jobs=[],ctx={waitUntil(job){jobs.push(job);}};
  const request=(path,body,cookie,origin=env.APP_ORIGIN)=>new Request(env.APP_ORIGIN+path,{method:body?'POST':'GET',headers:{Origin:origin,...(body?{'Content-Type':'application/json'}:{}),...(cookie?{Cookie:cookie}:{})},...(body?{body:JSON.stringify(body)}:{})});
  return {sqlite,env,ctx,jobs,code,request};
}
test('Cloudflare SQLite session, atomic reservation, streaming, replay and quota',async()=>{
  const f=fixture(),originalFetch=globalThis.fetch;let upstreamCalls=0;
  try{
    const login=await handleApi(f.request('/api/trial/session',{code:f.code}),f.env,f.ctx);assert.equal(login.status,200);const cookie=login.headers.get('set-cookie').split(';')[0];assert.ok(login.headers.get('set-cookie').includes('Secure'));
    globalThis.fetch=async(_url,options)=>{upstreamCalls++;const user=JSON.parse(JSON.parse(options.body).messages[1].content),id=user.candidates[0].id;return Response.json({choices:[{message:{content:JSON.stringify({summary:'真实结构测试',recommendations:[{competitionId:id,role:'main',reason:'方向相关',gaps:['核对条件'],pending:['查询通知']}],weeks:[1,2,3,4].map(week=>({week,tasks:[{competitionId:id,title:'阅读资料',hours:1}]}))})}}],usage:{total_tokens:30}});};
    const body={requestId:'cloudflare_0001',profile:{...DEFAULT_PROFILE,interests:['code']}};
    const generated=await handleApi(f.request('/api/plans/generate',body,cookie),f.env,f.ctx);const events=(await generated.text()).trim().split('\n').map(JSON.parse);await Promise.all(f.jobs);
    assert.deepEqual(events.map(x=>x.type),['status','status','result']);assert.equal(upstreamCalls,1);
    const replay=await handleApi(f.request('/api/plans/generate',body,cookie),f.env,f.ctx);assert.ok((await replay.text()).includes('"replayed":true'));assert.equal(upstreamCalls,1);
    await assert.rejects(()=>handleApi(f.request('/api/plans/generate',{...body,requestId:'cloudflare_0002'},cookie),f.env,f.ctx),error=>error.status===429);
    const cap=await(await handleApi(f.request('/api/capabilities',null,cookie),f.env,f.ctx)).json();assert.equal(cap.remaining,0);
  }finally{globalThis.fetch=originalFetch;f.sqlite.close();}
});
test('Cloudflare origin rejection and session requirement',async()=>{const f=fixture();try{await assert.rejects(()=>handleApi(f.request('/api/trial/session',{code:f.code},null,'https://evil.invalid'),f.env,f.ctx),error=>error.status===403);await assert.rejects(()=>handleApi(f.request('/api/feedback',{kind:'feedback'}),f.env,f.ctx),error=>error.status===401);}finally{f.sqlite.close();}});
test('Cloudflare atomic reservation rejects concurrent request per trial',async()=>{
  const f=fixture(),originalFetch=globalThis.fetch;
  try{
    const login=await handleApi(f.request('/api/trial/session',{code:f.code}),f.env,f.ctx),cookie=login.headers.get('set-cookie').split(';')[0];
    globalThis.fetch=async()=>Response.json({}, {status:502});
    const body={requestId:'cloudflare_running',profile:{...DEFAULT_PROFILE,interests:['code']}};
    const generated=await handleApi(f.request('/api/plans/generate',body,cookie),f.env,f.ctx);
    await assert.rejects(()=>handleApi(f.request('/api/plans/generate',{...body,requestId:'cloudflare_other'},cookie),f.env,f.ctx),error=>error.status===429);
    assert.ok((await generated.text()).includes('"type":"error"'));await Promise.all(f.jobs);
    assert.equal(f.sqlite.prepare("SELECT count(*) n FROM calls WHERE status='success'").get().n,0);
  }finally{globalThis.fetch=originalFetch;f.sqlite.close();}
});
