import {createServer} from 'node:http';
import {readFileSync,existsSync} from 'node:fs';
import {resolve,extname} from 'node:path';
import {pathToFileURL} from 'node:url';
import {randomBytes} from 'node:crypto';
import {openStore,hash} from './store.mjs';
import {normalizeCompetition,validateProfile,rankCandidates,validatePlan,parseModelJson,beijingDay} from '../shared/core.js';

const ROOT=resolve(import.meta.dirname,'..');
const CATALOG=JSON.parse(readFileSync(resolve(ROOT,'competitions_enriched.json'),'utf8')).map(normalizeCompetition);
function apiError(message,status=400){return Object.assign(new Error(message),{status});}
function integer(value,fallback){const n=Number(value);return Number.isInteger(n)&&n>0?n:fallback;}
async function readJson(req){let text='';for await(const chunk of req){text+=chunk;if(Buffer.byteLength(text)>32768)throw apiError('请求内容过长',413);}try{return JSON.parse(text);}catch{throw apiError('请求格式无效');}}
export function createApp(options={}) {
  const env=options.env||process.env;
  const db=options.db||openStore(env.DB_PATH||resolve(ROOT,'runtime/compass.sqlite'));
  db.prepare("UPDATE calls SET status='interrupted' WHERE status='running'").run();
  const upstreamFetch=options.fetch||fetch;
  const config={origin:env.APP_ORIGIN||`http://127.0.0.1:${env.PORT||4173}`,base:env.LLM_BASE_URL||'',model:env.LLM_MODEL||'',key:env.LLM_API_KEY||'',timeout:integer(env.LLM_TIMEOUT_MS,90000),daily:integer(env.TRIAL_DAILY_LIMIT,3),global:integer(env.GLOBAL_DAILY_LIMIT,100),concurrent:integer(env.MAX_CONCURRENT,2)};
  let active=0;
  const runningTrials=new Set();
  function session(req){const token=(req.headers.cookie||'').split(';').map(x=>x.trim()).find(x=>x.startsWith('compass_session='))?.slice(16);if(!token)return null;
    return db.prepare('SELECT s.trial_id FROM sessions s JOIN trials t ON t.id=s.trial_id WHERE s.token_hash=? AND s.expires>? AND t.active=1').get(hash(token),Date.now());}
  function remaining(id){return Math.max(0,config.daily-Number(db.prepare("SELECT count(*) AS n FROM calls WHERE trial_id=? AND day=? AND status='success'").get(id,beijingDay()).n));}
  const ready=()=>Boolean(config.base&&config.model&&config.key);
  function json(res,status,body){res.writeHead(status,{'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify(body));}
  const server=createServer(async(req,res)=>{
    res.setHeader('X-Content-Type-Options','nosniff');res.setHeader('Referrer-Policy','no-referrer');res.setHeader('Cache-Control','no-store');
    res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
    try {
      const url=new URL(req.url,'http://local');
      if(url.pathname.startsWith('/api/')){
        if(req.method==='POST' && req.headers.origin!==config.origin)throw apiError('请求来源不受信任',403);
        if(req.method==='POST'&&!req.headers['content-type']?.startsWith('application/json'))throw apiError('需要 JSON 请求',415);
        if(url.pathname==='/api/capabilities'&&req.method==='GET'){
          const s=session(req);return json(res,200,{configured:ready(),authenticated:!!s,remaining:s?remaining(s.trial_id):0,dailyLimit:config.daily});
        }
        if(url.pathname==='/api/trial/session'&&req.method==='POST'){
          const ip=hash(req.socket.remoteAddress||'local'),now=Date.now();
          const attempt=db.prepare('SELECT * FROM attempts WHERE ip_hash=?').get(ip);
          if(attempt&&now-attempt.start<900000&&attempt.count>=10)throw apiError('尝试过于频繁，请十五分钟后重试',429);
          db.prepare('INSERT INTO attempts(ip_hash,start,count) VALUES(?,?,1) ON CONFLICT(ip_hash) DO UPDATE SET start=?,count=?').run(ip,now,attempt&&now-attempt.start<900000?attempt.start:now,attempt&&now-attempt.start<900000?attempt.count+1:1);
          const body=await readJson(req);if(typeof body.code!=='string'||body.code.length>100)throw apiError('试用码无效');
          const trial=db.prepare('SELECT id FROM trials WHERE code_hash=? AND active=1').get(hash(body.code.trim()));if(!trial)throw apiError('试用码无效',401);
          const token=randomBytes(32).toString('base64url');db.prepare('INSERT INTO sessions VALUES(?,?,?)').run(hash(token),trial.id,now+30*86400000);
          res.setHeader('Set-Cookie',`compass_session=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000${config.origin.startsWith('https:')?'; Secure':''}`);
          return json(res,200,{ok:true,remaining:remaining(trial.id)});
        }
        const s=session(req);if(!s)throw apiError('请先兑换试用码',401);
        if(url.pathname==='/api/feedback'&&req.method==='POST'){
          const body=await readJson(req);
          if(!['feedback','request-trial','save','export'].includes(body.kind)||typeof(body.note||'')!=='string'||(body.note||'').length>1500||!['yes','no','partly',''].includes(body.useful||''))throw apiError('反馈格式无效');
          const recent=db.prepare('SELECT count(*) AS n FROM feedback WHERE trial_id=? AND created_at>?').get(s.trial_id,new Date(Date.now()-3600000).toISOString()).n;if(recent>=30)throw apiError('反馈过于频繁，请稍后再试',429);
          if(['save','export'].includes(body.kind))db.prepare('INSERT INTO events(trial_id,name,created_at) VALUES(?,?,?)').run(s.trial_id,body.kind,new Date().toISOString());
          db.prepare('INSERT INTO feedback(trial_id,kind,useful,note,created_at) VALUES(?,?,?,?,?)').run(s.trial_id,body.kind,body.useful||'',body.note||'',new Date().toISOString());
          return json(res,200,{ok:true});
        }
        if(url.pathname==='/api/plans/generate'&&req.method==='POST'){
          if(!ready())throw apiError('模型尚未配置，请先使用基础推荐',503);
          const body=await readJson(req);const profile=validateProfile(body.profile);
          if(typeof body.requestId!=='string'||!/^[a-zA-Z0-9_-]{8,80}$/.test(body.requestId))throw apiError('请求编号无效');
          const excluded=body.excluded||[];if(!Array.isArray(excluded)||excluded.length>247||!excluded.every(Number.isInteger))throw apiError('替换赛事参数无效');
          const prior=db.prepare('SELECT status,result FROM calls WHERE trial_id=? AND request_id=?').get(s.trial_id,body.requestId);
          if(prior){if(prior.status==='success'&&prior.result){res.writeHead(200,{'Content-Type':'application/x-ndjson; charset=utf-8'});return res.end(JSON.stringify({type:'result',data:JSON.parse(prior.result),replayed:true})+'\n');}throw apiError('该请求已处理或正在运行，请使用新的请求编号',409);}
          if(runningTrials.has(s.trial_id))throw apiError('已有规划正在生成，请稍后再试',409);
          if(!remaining(s.trial_id))throw apiError('今日试用次数已用完，可以反馈或明天继续',429);
          if(active>=config.concurrent)throw apiError('当前生成任务较多，请稍后再试',429);
          const count=db.prepare('SELECT count(*) AS n FROM calls WHERE day=?').get(beijingDay()).n;if(count>=config.global)throw apiError('今日全站试用额度已用完',429);
          const candidates=rankCandidates(CATALOG,profile,excluded);if(!candidates.length)throw apiError('当前没有符合条件的候选赛事');
          active++;runningTrials.add(s.trial_id);
          db.prepare('INSERT INTO calls(trial_id,request_id,day,status,created_at) VALUES(?,?,?,?,?)').run(s.trial_id,body.requestId,beijingDay(),'running',new Date().toISOString());
          const started=Date.now(),abort=new AbortController();let timeoutHit=false;
          const timer=setTimeout(()=>{timeoutHit=true;abort.abort();},config.timeout);
          const disconnect=()=>{if(!res.writableEnded)abort.abort();};res.on('close',disconnect);
          const send=(type,data)=>{if(!res.destroyed)res.write(JSON.stringify({type,...(type==='result'?{data}:{message:data})})+'\n');};
          res.writeHead(200,{'Content-Type':'application/x-ndjson; charset=utf-8','X-Accel-Buffering':'no'});
          let tokens=0;
          try{
            send('status','已完成候选筛选，正在请求模型');
            const schema={summary:'简短策略',recommendations:[{competitionId:1,role:'main | practice | backup',reason:'推荐原因',gaps:['能力缺口'],pending:['待确认事项']}],weeks:[{week:1,tasks:[{competitionId:1,title:'任务',hours:2}]}]};
            const upstream=await upstreamFetch(config.base.replace(/\/$/,'')+'/chat/completions',{method:'POST',signal:abort.signal,headers:{'Authorization':`Bearer ${config.key}`,'Content-Type':'application/json'},body:JSON.stringify({model:config.model,stream:false,max_tokens:8000,messages:[{role:'system',content:'你是校园竞赛规划助手。仅输出 JSON，不用 Markdown。只可选提供的赛事 ID。输出1至3个推荐，角色唯一且必须有 main。输出连续4周，每周任务工时之和不得超过用户预算。不可编造资格、赛程、来源、分数和成功概率。只给学习练习与核验任务，不将报名视为已开放。所有文字是普通文本。格式：'+JSON.stringify(schema)},{role:'user',content:JSON.stringify({profile,candidates:candidates.map(c=>({id:c.id,name:c.name,tags:c.tags,level:c.level,remarks:c.remarks,eligibility:c.eligibility,scheduleNote:c.scheduleNote}))})}]})});
            if(!upstream.ok){await upstream.body?.cancel();throw apiError('模型服务暂时不可用，请稍后重试',502);}
            const payload=await upstream.json();tokens=Number.isFinite(payload.usage?.total_tokens)?Math.max(0,Math.floor(payload.usage.total_tokens)):0;
            send('status','模型已返回，正在核对赛事与每周时间');
            let raw;try{raw=parseModelJson(payload.choices?.[0]?.message?.content);}catch{throw apiError('模型输出格式无效，请重试或使用基础推荐',502);}
            const plan=validatePlan(raw,candidates,profile);
            if(abort.signal.aborted)throw apiError('生成已取消');
            db.prepare("UPDATE calls SET status='success',duration_ms=?,tokens=?,result=? WHERE trial_id=? AND request_id=?").run(Date.now()-started,tokens,JSON.stringify(plan),s.trial_id,body.requestId);
            send('result',plan);res.end();
          }catch(error){
            db.prepare("UPDATE calls SET status=?,duration_ms=?,tokens=? WHERE trial_id=? AND request_id=?").run(abort.signal.aborted?'cancelled':'failed',Date.now()-started,tokens,s.trial_id,body.requestId);
            send('error',timeoutHit?'模型响应超时，未扣除有效生成次数':abort.signal.aborted?'生成已取消':error.status?error.message:error.message?.includes('校验')?error.message:'模型服务返回异常，请稍后重试');res.end();
          }finally{clearTimeout(timer);res.off('close',disconnect);active--;runningTrials.delete(s.trial_id);}
          return;
        }
        throw apiError('接口不存在',404);
      }
      if(req.method!=='GET'&&req.method!=='HEAD')throw apiError('不支持的请求方法',405);
      const sources={'/sources/catalog.pdf':'附件：西安建筑科技大学学生学科竞赛分级分类一览表（2025）.pdf','/sources/civil.pdf':'土木院 2025 级本科生学分认定细则（试行）.pdf'};
      let file;
      if(url.pathname==='/'||url.pathname==='/index.html')file=resolve(ROOT,'index.html');
      else if(sources[url.pathname])file=resolve(ROOT,sources[url.pathname]);
      else if(/^\/(public|shared)\/[a-zA-Z0-9_-]+\.(js|css|svg)$/.test(url.pathname))file=resolve(ROOT,'.'+url.pathname);
      if(!file||!existsSync(file))throw apiError('页面不存在',404);
      const type={'.html':'text/html','.css':'text/css','.js':'text/javascript','.svg':'image/svg+xml','.pdf':'application/pdf'}[extname(file)];
      const buffer=readFileSync(file);res.writeHead(200,{'Content-Type':type+'; charset=utf-8','Content-Length':buffer.length});res.end(req.method==='HEAD'?undefined:buffer);
    }catch(error){if(!res.headersSent)json(res,error.status||400,{error:error.status?error.message:'输入内容无效，请检查后重试'});else res.end();}
  });
  return {server,db};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){const {server}=createApp();server.listen(Number(process.env.PORT)||4173,process.env.HOST||'127.0.0.1',()=>console.log(`Compass listening at ${process.env.APP_ORIGIN||'http://127.0.0.1:4173'}`));}
