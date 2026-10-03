import {DEFAULT_PROFILE,validateProfile,validateTasks,beijingDay} from './core.js';
import {COMPETITIONS} from '../public/data.js';

const encode=new TextEncoder();
const ITERATIONS=100000;
const knownIds=new Set(COMPETITIONS.map(item=>item.id));
const fail=(message,status=400)=>Object.assign(new Error(message),{status});
export const requiresAccounts=env=>env.ACCOUNTS_REQUIRED!=='0';
export const jsonResponse=(data,status=200,extra={})=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff',...extra}});
export async function digest(value){return [...new Uint8Array(await crypto.subtle.digest('SHA-256',encode.encode(value)))].map(n=>n.toString(16).padStart(2,'0')).join('');}
export function randomSecret(size=32){return [...crypto.getRandomValues(new Uint8Array(size))].map(n=>n.toString(16).padStart(2,'0')).join('');}
function username(value){if(typeof value!=='string'||!/^[a-zA-Z0-9][a-zA-Z0-9_.-]{2,31}$/.test(value))throw fail('用户名需为 3—32 位字母、数字、下划线或短横线');return value.toLowerCase();}
function displayName(value,fallback){if(value===undefined||value==='')return fallback;if(typeof value!=='string'||value.trim().length<1||value.trim().length>32)throw fail('昵称需为 1—32 个字符');return value.trim();}
function password(value){if(typeof value!=='string'||value.length<10||value.length>128)throw fail('密码需为 10—128 个字符，建议使用较长的短语');return value;}
function pepper(env){if(typeof env.AUTH_PEPPER!=='string'||env.AUTH_PEPPER.length<32)throw fail('账号服务尚未配置，请稍后再试',503);return env.AUTH_PEPPER;}
async function passwordHash(value,salt,iterations,env){
  // HMAC pepper prevents a database-only leak from being enough to check guesses.
  const key=await crypto.subtle.importKey('raw',encode.encode(pepper(env)),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const material=await crypto.subtle.sign('HMAC',key,encode.encode(value));
  const passwordKey=await crypto.subtle.importKey('raw',material,'PBKDF2',false,['deriveBits']);
  const bits=await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt:encode.encode(salt),iterations},passwordKey,256);
  return [...new Uint8Array(bits)].map(n=>n.toString(16).padStart(2,'0')).join('');
}
function equalHash(a,b){let mismatch=a.length^b.length;for(let i=0;i<Math.max(a.length,b.length);i++)mismatch|=(a.charCodeAt(i)||0)^(b.charCodeAt(i)||0);return mismatch===0;}
export function publicUser(user){return {id:user.id,username:user.username,displayName:user.display_name,role:user.role,status:user.status,dailyGrant:user.daily_grant,mustChangePassword:!!user.must_change_password,createdAt:user.created_at,lastLoginAt:user.last_login_at};}
export async function readBody(request,max=32768){
  if(!request.headers.get('content-type')?.startsWith('application/json'))throw fail('需要 JSON 请求',415);
  const reader=request.body?.getReader();if(!reader)throw fail('请求格式无效');let bytes=0;const parts=[];
  while(true){const {done,value}=await reader.read();if(done)break;bytes+=value.byteLength;if(bytes>max){await reader.cancel();throw fail('请求内容过长',413);}parts.push(value);}
  const data=new Uint8Array(bytes);let offset=0;for(const part of parts){data.set(part,offset);offset+=part.byteLength;}
  try{return JSON.parse(new TextDecoder().decode(data));}catch{throw fail('请求格式无效');}
}
export function requireOrigin(request,env){if(!['GET','HEAD'].includes(request.method)&&request.headers.get('origin')!==(env.APP_ORIGIN||'https://compass.lzso.top'))throw fail('请求来源不受信任',403);}
function cookieValue(request,name){return (request.headers.get('cookie')||'').split(';').map(s=>s.trim()).find(s=>s.startsWith(name+'='))?.slice(name.length+1);}
export async function currentUser(request,env){
  const token=cookieValue(request,'compass_user');if(!token||token.length>150)return null;
  return env.DB.prepare('SELECT u.* FROM users u JOIN user_sessions s ON s.user_id=u.id WHERE s.token_hash=? AND s.expires>?').bind(await digest(token),Date.now()).first();
}
export async function requireUser(request,env,{admin=false,allowPasswordChange=false}={}){
  const user=await currentUser(request,env);if(!user)throw fail('请先登录账号',401);if(user.status!=='active')throw fail('账号已停用，请联系维护者',403);
  if(user.must_change_password&&!allowPasswordChange)throw fail('请先修改临时密码',403);
  if(admin&&user.role!=='admin')throw fail('需要管理员权限',403);return user;
}
async function rateLimit(request,env,namespace,max,windowMs=900000){
  const key=await digest(namespace+'|'+(request.headers.get('cf-connecting-ip')||'local')),now=Date.now();
  await env.DB.prepare(`INSERT INTO attempts(ip_hash,start,count) VALUES(?,?,1) ON CONFLICT(ip_hash) DO UPDATE SET count=CASE WHEN start>? THEN count+1 ELSE 1 END,start=CASE WHEN start>? THEN start ELSE ? END`).bind(key,now,now-windowMs,now-windowMs,now).run();
  const row=await env.DB.prepare('SELECT count FROM attempts WHERE ip_hash=?').bind(key).first();if(row.count>max)throw fail('尝试过于频繁，请稍后再试',429);
}
async function failedUsernameLimit(name,env){const key=await digest('login-user|'+name),row=await env.DB.prepare('SELECT start,count FROM attempts WHERE ip_hash=?').bind(key).first();if(row&&row.start>Date.now()-900000&&row.count>=10)throw fail('该账号尝试过于频繁，请十五分钟后重试',429);return key;}
async function recordFailedLogin(key,env){const now=Date.now();await env.DB.prepare(`INSERT INTO attempts VALUES(?,?,1) ON CONFLICT(ip_hash) DO UPDATE SET count=CASE WHEN start>? THEN count+1 ELSE 1 END,start=CASE WHEN start>? THEN start ELSE ? END`).bind(key,now,now-900000,now-900000,now).run();}
async function issueSession(user,env){
  const value=randomSecret();await env.DB.prepare('INSERT INTO user_sessions VALUES(?,?,?)').bind(await digest(value),user.id,Date.now()+30*86400000).run();
  const secure=(env.APP_ORIGIN||'').startsWith('https:')?'; Secure':'';
  return `compass_user=${value}; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000${secure}`;
}
export function normalizeWorkspace(value){
  if(!value||value.version!==2)throw fail('计划数据版本无效');
  let tasks,profile;try{tasks=validateTasks(value.tasks);profile=validateProfile(value.profile);}catch(error){throw fail(error.message);}
  if(tasks.some(task=>!knownIds.has(task.competitionId))||new Set(tasks.map(task=>task.id)).size!==tasks.length)throw fail('计划包含未知赛事或重复任务');
  if(!Array.isArray(value.favorites)||value.favorites.length>247||value.favorites.some(id=>!knownIds.has(id)))throw fail('收藏数据无效');
  return {version:2,tasks,profile,favorites:[...new Set(value.favorites)]};
}
const emptyWorkspace=()=>({version:2,tasks:[],favorites:[],profile:{...DEFAULT_PROFILE}});
export async function userTrials(user,env){
  const result=await env.DB.prepare(`SELECT t.id,t.kind,t.active,t.daily_limit,t.created_at,t.claimed_at,
    (SELECT count(*) FROM calls c WHERE c.trial_id=t.id AND c.day=? AND c.status='success') AS used
    FROM trials t WHERE t.owner_user_id=? ORDER BY t.id`).bind(beijingDay(),user.id).all();
  return result.results.map(t=>({...t,remaining:t.active?Math.max(0,t.daily_limit-t.used):0}));
}
export async function generationIdentity(request,env){
  if(!requiresAccounts(env)){
    const token=cookieValue(request,'compass_session');if(!token)return null;
    const trial=await env.DB.prepare('SELECT t.id AS trial_id,t.daily_limit FROM sessions s JOIN trials t ON t.id=s.trial_id WHERE s.token_hash=? AND s.expires>? AND t.active=1').bind(await digest(token),Date.now()).first();return trial?{...trial,daily_limit:Number(env.TRIAL_DAILY_LIMIT)||3}:null;
  }
  const user=await requireUser(request,env);const trials=await userTrials(user,env),chosen=trials.find(t=>t.remaining>0)||trials.find(t=>t.active&&t.daily_limit>0);
  return chosen?{trial_id:chosen.id,daily_limit:chosen.daily_limit,user_id:user.id}:null;
}
async function audit(db,actor,action,target){return db.prepare('INSERT INTO account_audit(actor_id,action,target_id,created_at) VALUES(?,?,?,?)').bind(actor,action,target,new Date().toISOString());}

export async function bootstrapAdmin(body,env){
  const name=username(body.username),pw=password(body.password),salt=randomSecret(16),hash=await passwordHash(pw,salt,ITERATIONS,env),now=new Date().toISOString();
  const inserted=await env.DB.prepare(`INSERT INTO users(username,display_name,password_hash,password_salt,password_iterations,role,status,created_at)
    SELECT ?,?,?,?,?,'admin','active',? WHERE NOT EXISTS (SELECT 1 FROM users WHERE role='admin')`).bind(name,displayName(body.displayName,'项目管理员'),hash,salt,ITERATIONS,now).run();
  if(!inserted.meta.changes)throw fail('管理员已经存在，不会覆盖其密码',409);
  const user=await env.DB.prepare('SELECT * FROM users WHERE username=?').bind(name).first();
  await env.DB.prepare('INSERT INTO user_workspaces VALUES(?,?,0,?)').bind(user.id,JSON.stringify(emptyWorkspace()),now).run();return publicUser(user);
}
export async function recoverAdmin(body,env){
  const name=username(body.username),pw=password(body.password);
  const user=await env.DB.prepare("SELECT * FROM users WHERE username=? AND role='admin'").bind(name).first();if(!user)throw fail('管理员不存在',404);
  const salt=randomSecret(16),hash=await passwordHash(pw,salt,ITERATIONS,env);
  await env.DB.batch([env.DB.prepare("UPDATE users SET password_hash=?,password_salt=?,password_iterations=?,status='active',must_change_password=0 WHERE id=?").bind(hash,salt,ITERATIONS,user.id),env.DB.prepare('DELETE FROM user_sessions WHERE user_id=?').bind(user.id),await audit(env.DB,null,'recover-admin',user.id)]);
  return {username:name,recovered:true};
}

export async function handleAccountApi(request,env){
  const url=new URL(request.url),path=url.pathname,db=env.DB;requireOrigin(request,env);
  if(path==='/api/auth/me'&&request.method==='GET'){
    const user=await currentUser(request,env);if(user&&user.status!=='active')return jsonResponse({user:null,disabled:true});
    return jsonResponse({user:user?publicUser(user):null,accountsEnabled:!!env.AUTH_PEPPER});
  }
  if(['/api/auth/register','/api/auth/login'].includes(path)&&request.method==='POST'){
    pepper(env);const body=await readBody(request);const name=username(body.username),pw=password(body.password);let user;
    await rateLimit(request,env,path.endsWith('register')?'register':'login-ip',path.endsWith('register')?50:40);
    if(path.endsWith('register')){
      const existing=await db.prepare('SELECT id FROM users WHERE username=?').bind(name).first();if(existing)throw fail('该用户名已被使用',409);
      const salt=randomSecret(16),hash=await passwordHash(pw,salt,ITERATIONS,env),now=new Date().toISOString();
      await db.batch([db.prepare("INSERT INTO users(username,display_name,password_hash,password_salt,password_iterations,created_at) VALUES(?,?,?,?,?,?)").bind(name,displayName(body.displayName,name),hash,salt,ITERATIONS,now),db.prepare('INSERT INTO user_workspaces SELECT id,?,0,? FROM users WHERE username=?').bind(JSON.stringify(emptyWorkspace()),now,name)]);
      user=await db.prepare('SELECT * FROM users WHERE username=?').bind(name).first();
    }else{
      const failureKey=await failedUsernameLimit(name,env);
      user=await db.prepare('SELECT * FROM users WHERE username=?').bind(name).first();
      const computed=await passwordHash(pw,user?.password_salt||'00000000000000000000000000000000',user?.password_iterations||ITERATIONS,env);
      if(!user||!equalHash(computed,user.password_hash)){await recordFailedLogin(failureKey,env);throw fail('用户名或密码不正确',401);}
      if(user.status!=='active')throw fail('账号已停用，请联系维护者',403);
      await db.prepare('DELETE FROM attempts WHERE ip_hash=?').bind(failureKey).run();
    }
    await db.prepare('UPDATE users SET last_login_at=? WHERE id=?').bind(new Date().toISOString(),user.id).run();
    return jsonResponse({user:publicUser(user)},200,{'Set-Cookie':await issueSession(user,env)});
  }
  if(path==='/api/auth/logout'&&request.method==='POST'){
    const value=cookieValue(request,'compass_user');if(value)await db.prepare('DELETE FROM user_sessions WHERE token_hash=?').bind(await digest(value)).run();
    return jsonResponse({ok:true},200,{'Set-Cookie':`compass_user=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0${(env.APP_ORIGIN||'').startsWith('https:')?'; Secure':''}`});
  }
  const user=await requireUser(request,env,{admin:path.startsWith('/api/admin/'),allowPasswordChange:path==='/api/auth/password'});
  if(path==='/api/auth/password'&&request.method==='POST'){
    await rateLimit(request,env,'password-change',10);const body=await readBody(request),current=password(body.currentPassword),next=password(body.newPassword);
    if(!equalHash(await passwordHash(current,user.password_salt,user.password_iterations,env),user.password_hash))throw fail('当前密码不正确',401);
    const salt=randomSecret(16),hash=await passwordHash(next,salt,ITERATIONS,env);
    await db.batch([db.prepare('UPDATE users SET password_hash=?,password_salt=?,password_iterations=?,must_change_password=0 WHERE id=?').bind(hash,salt,ITERATIONS,user.id),db.prepare('DELETE FROM user_sessions WHERE user_id=?').bind(user.id)]);
    const updated={...user,password_hash:hash,password_salt:salt,must_change_password:0};return jsonResponse({ok:true,user:publicUser(updated)},200,{'Set-Cookie':await issueSession(updated,env)});
  }
  if(path==='/api/user/trials'&&request.method==='GET')return jsonResponse({trials:await userTrials(user,env)});
  if(path==='/api/user/workspace'&&request.method==='GET'){
    const row=await db.prepare('SELECT * FROM user_workspaces WHERE user_id=?').bind(user.id).first();return jsonResponse({revision:row?.revision||0,payload:row?JSON.parse(row.payload):emptyWorkspace(),updatedAt:row?.updated_at||null});
  }
  if(path==='/api/user/workspace'&&request.method==='POST'){
    const body=await readBody(request,512000);if(!Number.isInteger(body.revision)||body.revision<0)throw fail('同步版本无效');const payload=normalizeWorkspace(body.payload),now=new Date().toISOString();
    const saved=await db.prepare('UPDATE user_workspaces SET payload=?,revision=revision+1,updated_at=? WHERE user_id=? AND revision=?').bind(JSON.stringify(payload),now,user.id,body.revision).run();
    if(!saved.meta.changes)throw fail('云端计划已有更新，本机改动已保留，请选择要保留的版本',409);return jsonResponse({ok:true,revision:body.revision+1,updatedAt:now});
  }
  if(path==='/api/admin/overview'&&request.method==='GET'){
    const users=await db.prepare('SELECT count(*) total,sum(status=\'active\') active FROM users').first();
    const cards=await db.prepare("SELECT count(*) total,sum(active=1) active,sum(owner_user_id IS NOT NULL) bound FROM trials WHERE kind='redeem'").first();
    const usage=await db.prepare("SELECT count(*) requests,sum(status='success') successes,coalesce(sum(tokens),0) tokens FROM calls WHERE day=?").bind(beijingDay()).first();return jsonResponse({users,cards,usage});
  }
  if(path==='/api/admin/users'&&request.method==='GET'){
    const cursor=Math.max(0,Number(url.searchParams.get('cursor'))||0),query=(url.searchParams.get('query')||'').slice(0,64);
    const rows=await db.prepare('SELECT * FROM users WHERE id>? AND (username LIKE ? OR display_name LIKE ?) ORDER BY id LIMIT 51').bind(cursor,'%'+query+'%','%'+query+'%').all();const list=rows.results;return jsonResponse({users:list.slice(0,50).map(publicUser),nextCursor:list.length>50?list[49].id:null});
  }
  if(path==='/api/admin/trials'&&request.method==='GET'){
    const cursor=Math.max(0,Number(url.searchParams.get('cursor'))||0);
    const rows=await db.prepare(`SELECT t.id,t.kind,t.active,t.daily_limit,t.created_at,t.claimed_at,u.username owner,
      (SELECT count(*) FROM calls c WHERE c.trial_id=t.id AND c.day=? AND c.status='success') used
      FROM trials t LEFT JOIN users u ON u.id=t.owner_user_id WHERE t.kind='redeem' AND t.id>? ORDER BY t.id LIMIT 51`).bind(beijingDay(),cursor).all();return jsonResponse({trials:rows.results.slice(0,50),nextCursor:rows.results.length>50?rows.results[49].id:null});
  }
  if(path==='/api/admin/users/update'&&request.method==='POST'){
    const body=await readBody(request);if(!Number.isInteger(body.userId)||body.userId<1)throw fail('用户编号无效');const target=await db.prepare('SELECT * FROM users WHERE id=?').bind(body.userId).first();if(!target)throw fail('用户不存在',404);
    const status=body.status??target.status,role=body.role??target.role,grant=body.dailyGrant??target.daily_grant;
    if(!['active','disabled'].includes(status)||!['admin','user'].includes(role)||!Number.isInteger(grant)||grant<0||grant>100)throw fail('权益或账号状态无效');
    if(user.id===target.id&&(status!=='active'||role!=='admin'))throw fail('不能停用或降级当前管理员账号');
    const changed=await db.prepare(`UPDATE users SET status=?,role=?,daily_grant=? WHERE id=? AND NOT(role='admin' AND status='active' AND (?<>'admin' OR ?<>'active') AND (SELECT count(*) FROM users WHERE role='admin' AND status='active')<=1)`).bind(status,role,grant,target.id,role,status).run();
    if(!changed.meta.changes)throw fail('必须保留至少一个可用的管理员',409);
    const internalHash=await digest('account-grant:'+target.id+':'+pepper(env));
    const statements=[db.prepare(`INSERT INTO trials(code_hash,created_at,active,owner_user_id,daily_limit,kind) VALUES(?,?,?,?,?,'grant') ON CONFLICT(code_hash) DO UPDATE SET daily_limit=?,active=?`).bind(internalHash,new Date().toISOString(),grant>0?1:0,target.id,grant,grant,grant>0?1:0),await audit(db,user.id,'update-user',target.id)];
    if(status==='disabled')statements.push(db.prepare('DELETE FROM user_sessions WHERE user_id=?').bind(target.id));await db.batch(statements);return jsonResponse({ok:true});
  }
  if(path==='/api/admin/users/reset-password'&&request.method==='POST'){
    const body=await readBody(request);if(!Number.isInteger(body.userId)||body.userId===user.id)throw fail('请在账号设置中修改自己的密码');const target=await db.prepare('SELECT * FROM users WHERE id=?').bind(body.userId).first();if(!target)throw fail('用户不存在',404);
    const temporaryPassword='Cp!'+randomSecret(12),salt=randomSecret(16),hash=await passwordHash(temporaryPassword,salt,ITERATIONS,env);
    await db.batch([db.prepare('UPDATE users SET password_hash=?,password_salt=?,password_iterations=?,must_change_password=1 WHERE id=?').bind(hash,salt,ITERATIONS,target.id),db.prepare('DELETE FROM user_sessions WHERE user_id=?').bind(target.id),await audit(db,user.id,'reset-password',target.id)]);
    return jsonResponse({username:target.username,temporaryPassword,mustChangePassword:true});
  }
  if(path==='/api/admin/trials/create'&&request.method==='POST'){
    const body=await readBody(request);const count=body.count,limit=body.dailyLimit??3;if(!Number.isInteger(count)||count<1||count>50||!Number.isInteger(limit)||limit<1||limit>100)throw fail('卡密数量或额度无效');
    const codes=[];for(let i=0;i<count;i++)codes.push('CP-'+randomSecret(12));
    const statements=await Promise.all(codes.map(async code=>db.prepare('INSERT INTO trials(code_hash,created_at,daily_limit) VALUES(?,?,?)').bind(await digest(code),new Date().toISOString(),limit)));statements.push(await audit(db,user.id,'create-cards',count));await db.batch(statements);return jsonResponse({codes,dailyLimit:limit});
  }
  if(path==='/api/admin/trials/update'&&request.method==='POST'){
    const body=await readBody(request);const target=await db.prepare("SELECT * FROM trials WHERE id=? AND kind='redeem'").bind(Number.isInteger(body.trialId)?body.trialId:0).first();if(!target)throw fail('卡密不存在',404);const active=body.active??target.active,limit=body.dailyLimit??target.daily_limit;if(![0,1].includes(active)||!Number.isInteger(limit)||limit<1||limit>100)throw fail('卡密状态或额度无效');
    await db.batch([db.prepare('UPDATE trials SET active=?,daily_limit=? WHERE id=?').bind(active,limit,target.id),await audit(db,user.id,'update-card',target.id)]);return jsonResponse({ok:true});
  }
  throw fail('接口不存在',404);
}
