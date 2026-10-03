import {COMPETITIONS} from '../public/data.js';
import {validateProfile,rankCandidates,validatePlan,parseModelJson,beijingDay} from '../shared/core.js';
import {handleAccountApi,currentUser,requireUser,publicUser,userTrials,generationIdentity,requiresAccounts} from '../shared/accounts.js';

const encoder=new TextEncoder();
const securityHeaders={
  'X-Content-Type-Options':'nosniff',
  'Referrer-Policy':'no-referrer',
  'Cache-Control':'no-store',
  'Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
};
const problem=(message,status=400)=>Object.assign(new Error(message),{status});
const positive=(value,fallback)=>Number.isInteger(Number(value))&&Number(value)>0?Number(value):fallback;
async function sha(value){return [...new Uint8Array(await crypto.subtle.digest('SHA-256',encoder.encode(value)))].map(x=>x.toString(16).padStart(2,'0')).join('');}
function token(){return [...crypto.getRandomValues(new Uint8Array(32))].map(x=>x.toString(16).padStart(2,'0')).join('');}
async function jsonBody(request){
  if(!request.headers.get('content-type')?.startsWith('application/json'))throw problem('需要 JSON 请求',415);
  const reader=request.body?.getReader();if(!reader)throw problem('请求格式无效');
  const parts=[];let total=0;
  while(true){const {done,value}=await reader.read();if(done)break;total+=value.byteLength;if(total>32768){await reader.cancel();throw problem('请求内容过长',413);}parts.push(value);}
  const body=new Uint8Array(total);let offset=0;for(const part of parts){body.set(part,offset);offset+=part.byteLength;}
  try{return JSON.parse(new TextDecoder().decode(body));}catch{throw problem('请求格式无效');}
}
function responseJson(data,status=200,headers={}){return new Response(JSON.stringify(data),{status,headers:{...securityHeaders,'Content-Type':'application/json; charset=utf-8',...headers}});}
async function session(request,db){const cookie=request.headers.get('cookie')||'';const value=cookie.split(';').map(s=>s.trim()).find(s=>s.startsWith('compass_session='))?.slice(16);if(!value||value.length>150)return null;return db.prepare('SELECT s.trial_id FROM sessions s JOIN trials t ON t.id=s.trial_id WHERE s.token_hash=? AND s.expires>? AND t.active=1').bind(await sha(value),Date.now()).first();}
async function remaining(db,id,limit){const value=await db.prepare("SELECT count(*) n FROM calls WHERE trial_id=? AND day=? AND status='success'").bind(id,beijingDay()).first();return Math.max(0,limit-value.n);}
function configuration(env){return {origin:env.APP_ORIGIN||'https://compass.lzso.top',base:env.LLM_BASE_URL||'',model:env.LLM_MODEL||'',key:env.LLM_API_KEY||'',daily:positive(env.TRIAL_DAILY_LIMIT,3),global:positive(env.GLOBAL_DAILY_LIMIT,100),concurrent:positive(env.MAX_CONCURRENT,2),timeout:positive(env.LLM_TIMEOUT_MS,90000)};}
const isReady=conf=>Boolean(conf.base&&conf.model&&conf.key);

export async function handleApi(request,env,ctx){
  const db=env.DB,conf=configuration(env),path=new URL(request.url).pathname;
  if(/^\/api\/(auth|user|admin)\//.test(path))return handleAccountApi(request,env);
  if(request.method==='POST'&&request.headers.get('origin')!==conf.origin)throw problem('请求来源不受信任',403);
  if(request.method==='GET'&&path==='/api/capabilities'){
    if(requiresAccounts(env)){
      const user=await currentUser(request,env);const usable=user?.status==='active'&&!user.must_change_password;
      const trials=usable?await userTrials(user,env):[];const left=trials.reduce((sum,trial)=>sum+trial.remaining,0);
      return responseJson({configured:isReady(conf),authenticated:trials.some(t=>t.active&&t.daily_limit>0),remaining:left,dailyLimit:trials.filter(t=>t.active).reduce((sum,t)=>sum+t.daily_limit,0),accountsRequired:true,user:usable?publicUser(user):null});
    }
    const s=await session(request,db);return responseJson({configured:isReady(conf),authenticated:!!s,remaining:s?await remaining(db,s.trial_id,conf.daily):0,dailyLimit:conf.daily,accountsRequired:false});
  }
  if(request.method==='POST'&&path==='/api/trial/session'){
    const ipHash=await sha(request.headers.get('cf-connecting-ip')||'unknown');
    const now=Date.now();
    await db.prepare(`INSERT INTO attempts(ip_hash,start,count) VALUES(?,?,1) ON CONFLICT(ip_hash) DO UPDATE SET count=CASE WHEN start>? THEN count+1 ELSE 1 END,start=CASE WHEN start>? THEN start ELSE ? END`).bind(ipHash,now,now-900000,now-900000,now).run();
    const attempt=await db.prepare('SELECT count FROM attempts WHERE ip_hash=?').bind(ipHash).first();if(attempt.count>10)throw problem('尝试过于频繁，请十五分钟后重试',429);
    const body=await jsonBody(request);if(typeof body.code!=='string'||body.code.length>100)throw problem('试用码无效');
    const trial=await db.prepare('SELECT id FROM trials WHERE code_hash=? AND active=1').bind(await sha(body.code.trim())).first();if(!trial)throw problem('试用码无效',401);
    if(requiresAccounts(env)){
      const user=await requireUser(request,env);
      const claimed=await db.prepare("UPDATE trials SET owner_user_id=?,claimed_at=coalesce(claimed_at,?) WHERE id=? AND kind='redeem' AND (owner_user_id IS NULL OR owner_user_id=?)").bind(user.id,new Date().toISOString(),trial.id,user.id).run();
      if(!claimed.meta.changes)throw problem('该卡密已绑定其他账号',409);
      const cards=await userTrials(user,env);return responseJson({ok:true,remaining:cards.reduce((sum,c)=>sum+c.remaining,0),bound:true});
    }
    const value=token();await db.prepare('INSERT INTO sessions VALUES(?,?,?)').bind(await sha(value),trial.id,now+30*86400000).run();
    return responseJson({ok:true,remaining:await remaining(db,trial.id,conf.daily)},200,{'Set-Cookie':`compass_session=${value}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=2592000`});
  }
  const account=requiresAccounts(env)?await requireUser(request,env):null;
  const s=requiresAccounts(env)?await generationIdentity(request,env):await session(request,db);
  if(!s&&!account)throw problem('请先兑换试用码',401);
  if(request.method==='POST'&&path==='/api/feedback'){
    const body=await jsonBody(request);
    if(!['feedback','request-trial','save','export'].includes(body.kind)||typeof(body.note||'')!=='string'||(body.note||'').length>1500||!['yes','no','partly',''].includes(body.useful||''))throw problem('反馈格式无效');
    const recent=account?await db.prepare('SELECT count(*) n FROM feedback WHERE user_id=? AND created_at>?').bind(account.id,new Date(Date.now()-3600000).toISOString()).first():await db.prepare('SELECT count(*) n FROM feedback WHERE trial_id=? AND created_at>?').bind(s.trial_id,new Date(Date.now()-3600000).toISOString()).first();if(recent.n>=30)throw problem('反馈过于频繁，请稍后再试',429);
    const queries=[db.prepare('INSERT INTO feedback(trial_id,kind,useful,note,created_at,user_id) VALUES(?,?,?,?,?,?)').bind(s?.trial_id||null,body.kind,body.useful||'',body.note||'',new Date().toISOString(),account?.id||null)];
    if(['save','export'].includes(body.kind))queries.push(account?db.prepare('INSERT INTO user_events(user_id,name,created_at) VALUES(?,?,?)').bind(account.id,body.kind,new Date().toISOString()):db.prepare('INSERT INTO events(trial_id,name,created_at) VALUES(?,?,?)').bind(s.trial_id,body.kind,new Date().toISOString()));
    await db.batch(queries);return responseJson({ok:true});
  }
  if(request.method!=='POST'||path!=='/api/plans/generate')throw problem('接口不存在',404);
  if(!s)throw problem('请先绑定卡密或联系管理员获取额度',403);
  if(!isReady(conf))throw problem('模型尚未配置，请先使用基础推荐',503);
  const body=await jsonBody(request);let profile;try{profile=validateProfile(body.profile);}catch(error){throw problem(error.message);}
  if(typeof body.requestId!=='string'||!/^[a-zA-Z0-9_-]{8,80}$/.test(body.requestId))throw problem('请求编号无效');
  const excluded=body.excluded||[];if(!Array.isArray(excluded)||excluded.length>247||!excluded.every(Number.isInteger))throw problem('替换赛事参数无效');
  const prior=account?await db.prepare('SELECT status,result FROM calls WHERE user_id=? AND request_id=?').bind(account.id,body.requestId).first():await db.prepare('SELECT status,result FROM calls WHERE trial_id=? AND request_id=?').bind(s.trial_id,body.requestId).first();
  if(prior){if(prior.status==='success'&&prior.result)return new Response(JSON.stringify({type:'result',data:JSON.parse(prior.result),replayed:true})+'\n',{headers:{...securityHeaders,'Content-Type':'application/x-ndjson; charset=utf-8'}});throw problem('该请求已处理或正在运行，请使用新的请求编号',409);}
  const candidates=rankCandidates(COMPETITIONS,profile,excluded);if(!candidates.length)throw problem('当前没有符合条件的候选赛事');
  const createdAt=new Date().toISOString(),liveCutoff=new Date(Date.now()-conf.timeout-10000).toISOString();
  // A single SQLite statement reserves budget atomically across all Worker instances.
  const limit=s.daily_limit??conf.daily;
  const reserved=await db.prepare(`INSERT INTO calls(trial_id,request_id,day,status,created_at,user_id)
    SELECT ?,?,?,'running',?,? WHERE
      (SELECT count(*) FROM calls WHERE day=?)<? AND
      (SELECT count(*) FROM calls WHERE trial_id=? AND day=? AND status='success')<? AND
      (SELECT count(*) FROM calls WHERE status='running' AND created_at>?)<? AND
      (SELECT count(*) FROM calls WHERE trial_id=? AND status='running' AND created_at>?)=0
    ON CONFLICT DO NOTHING`).bind(s.trial_id,body.requestId,beijingDay(),createdAt,account?.id||null,beijingDay(),conf.global,s.trial_id,beijingDay(),limit,liveCutoff,conf.concurrent,s.trial_id,liveCutoff).run();
  if(!reserved.meta?.changes)throw problem('额度已用完或已有规划正在生成，请稍后再试',429);
  const stream=new TransformStream(),writer=stream.writable.getWriter(),abort=new AbortController();let ended=false;
  writer.closed.catch(()=>{if(!ended)abort.abort();});
  const send=(type,message)=>writer.write(encoder.encode(JSON.stringify(type==='result'?{type,data:message}:{type,message})+'\n'));
  const job=(async()=>{
    const started=Date.now();let timedOut=false,tokens=0;
    const timer=setTimeout(()=>{timedOut=true;abort.abort();},conf.timeout);
    const cancel=()=>abort.abort();request.signal.addEventListener('abort',cancel,{once:true});
    try{
      await send('status','已完成候选筛选，正在请求模型');
      const schema={summary:'简短策略',recommendations:[{competitionId:1,role:'main | practice | backup',reason:'推荐原因',gaps:['能力缺口'],pending:['待确认事项']}],weeks:[{week:1,tasks:[{competitionId:1,title:'任务',hours:2}]}]};
      const result=await (env.UPSTREAM_FETCH||fetch)(conf.base.replace(/\/$/,'')+'/chat/completions',{method:'POST',signal:abort.signal,headers:{Authorization:`Bearer ${conf.key}`,'Content-Type':'application/json'},body:JSON.stringify({model:conf.model,stream:false,max_tokens:8000,messages:[{role:'system',content:'你是校园竞赛规划助手。仅输出 JSON，不用 Markdown。只可选提供的赛事 ID。输出1至3个推荐，角色唯一且必须有 main。输出连续4周，每周任务工时之和不得超过用户预算。不可编造资格、赛程、来源、分数和成功概率。只给学习练习与核验任务，不将报名视为已开放。所有文字是普通文本。格式：'+JSON.stringify(schema)},{role:'user',content:JSON.stringify({profile,candidates:candidates.map(c=>({id:c.id,name:c.name,tags:c.tags,level:c.level,remarks:c.remarks,eligibility:c.eligibility,scheduleNote:c.scheduleNote}))})}]})});
      if(!result.ok){await result.body?.cancel();throw problem('模型服务暂时不可用，请稍后重试',502);}
      const payload=await result.json();tokens=Number.isFinite(payload.usage?.total_tokens)?Math.max(0,Math.floor(payload.usage.total_tokens)):0;
      await send('status','模型已返回，正在核对赛事与每周时间');
      let raw;try{raw=parseModelJson(payload.choices?.[0]?.message?.content);}catch{console.warn('model_response_shape',JSON.stringify({finishReason:payload.choices?.[0]?.finish_reason,contentLength:payload.choices?.[0]?.message?.content?.length||0,startsWithFence:payload.choices?.[0]?.message?.content?.trim().startsWith('```')}));throw problem('模型输出格式无效，请重试或使用基础推荐',502);}
      const plan=validatePlan(raw,candidates,profile);if(abort.signal.aborted)throw problem('生成已取消');
      await db.prepare("UPDATE calls SET status='success',duration_ms=?,tokens=?,result=? WHERE trial_id=? AND request_id=?").bind(Date.now()-started,tokens,JSON.stringify(plan),s.trial_id,body.requestId).run();
      await send('result',plan);
    }catch(error){
      await db.prepare('UPDATE calls SET status=?,duration_ms=?,tokens=? WHERE trial_id=? AND request_id=?').bind(abort.signal.aborted?'cancelled':'failed',Date.now()-started,tokens,s.trial_id,body.requestId).run();
      try{await send('error',timedOut?'模型响应超时，未扣除有效生成次数':abort.signal.aborted?'生成已取消':error.status||error.message?.includes('校验')?error.message:'模型服务返回异常，请稍后重试');}catch{/* Client already disconnected. The outcome is persisted above. */}
    }finally{clearTimeout(timer);request.signal.removeEventListener('abort',cancel);ended=true;await writer.close().catch(()=>{});}
  })();
  ctx.waitUntil(job);
  return new Response(stream.readable,{headers:{...securityHeaders,'Content-Type':'application/x-ndjson; charset=utf-8'}});
}

export default {
  async fetch(request,env,ctx){
    try{
      if(new URL(request.url).pathname.startsWith('/api/'))return await handleApi(request,env,ctx);
      const asset=await env.ASSETS.fetch(request);const response=new Response(asset.body,asset);for(const [name,value]of Object.entries(securityHeaders))response.headers.set(name,value);return response;
    }catch(error){return responseJson({error:error.status?error.message:'输入内容无效，请检查后重试'},error.status||400);}
  }
};
