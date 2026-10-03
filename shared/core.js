export const INTERESTS = [
  ['math', '数学与建模'], ['code', '编程与 AI'], ['design', '设计与表达'],
  ['engineering', '工程与实践'], ['business', '创新与商业'], ['language', '语言与通识']
];
export const SKILLS = [['math', '数理分析'], ['code', '编程开发'], ['design', '视觉表达'], ['writing', '研究写作'], ['hardware', '动手实践'], ['present', '路演沟通']];
export const GOALS = [['explore', '探索兴趣'], ['practice', '积累作品'], ['credit', '了解学分'], ['challenge', '挑战自己']];
export const DEFAULT_PROFILE = {grade:'大一', college:'', goal:'explore', interests:[], skills:[], team:'尚未组队', hours:6};
export const RULE_VERSION = '土木学院 2025 级 / 2025—2026 学年参考';
export const SCORE_MATRIX = {'一类A1':[14,12,10], '一类A2':[14,12,10], '一类B':[12,10,8], '一类C':[10,8,6], '二类':[6,4,3], '三类':[3,2,1.5], '四类':[1,.5,.3]};
export function safeUrl(value) { try {const u = new URL(value); return ['https:','http:'].includes(u.protocol) ? u.href : '';} catch {return '';}}
export function escapeHtml(value) { return String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
export function validDate(value) { return typeof value==='string' && /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(Date.parse(value+'T12:00:00Z')) && new Date(value+'T12:00:00Z').toISOString().slice(0,10)===value; }
export function localDay(date = new Date()) {return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;}
export function beijingDay(date = new Date()) {return new Date(date.getTime()+8*3600000).toISOString().slice(0,10);}
export function inferTags(name) {
  const rules = {math:/数学|数学建模|统计|力学/,code:/计算机|程序|软件|人工智能|大数据|信息安全|蓝桥|ICT|算法/,design:/设计|建筑|规划|艺术|图形|成图|广告|创意/,engineering:/结构|机械|工程|机器人|电子|制造|材料|能源|化学|物理|测量|交通|金相/,business:/创新|创业|挑战杯|商业|商务|管理|营销|金融|财会|职业/,language:/英语|翻译|演讲|外语|语文|写作/};
  return Object.entries(rules).filter(([,r])=>r.test(name)).map(([k])=>k);
}
export function normalizeCompetition(c) {
  return {...c, tags:inferTags(c.name), website:safeUrl(c.website), edition:'2025 目录',
    directoryStatus:'recorded', scheduleStatus:'historical', verifiedAt:null, deadline:null,
    eligibility:c.name.includes('研究生')?'graduate':'unknown', eligibilitySource:'赛事名称，仅用于初步筛选',
    source:{title:'西安建筑科技大学学生学科竞赛分级分类一览表（2025）',url:'/sources/catalog.pdf',entry:c.id},
    scheduleNote:'历年参考；当届通知及校内截止时间待核验'};
}
export function validateProfile(input) {
  if (!input || typeof input!=='object') throw new Error('请填写选赛需求');
  const arr=(v,allowed)=>Array.isArray(v)&&v.length<=8&&v.every(x=>allowed.includes(x));
  if (!['大一','大二','大三','大四','研究生'].includes(input.grade) || !GOALS.some(([id])=>id===input.goal)
    || typeof input.college!=='string' || input.college.length>60 || !arr(input.interests,INTERESTS.map(x=>x[0]))
    || !arr(input.skills,SKILLS.map(x=>x[0])) || !['尚未组队','已有队友','已有指导老师'].includes(input.team)
    || !Number.isFinite(input.hours) || input.hours<1 || input.hours>30) throw new Error('画像格式无效，请检查年级、方向与时间预算');
  return {grade:input.grade,college:input.college.trim(),goal:input.goal,interests:[...new Set(input.interests)],skills:[...new Set(input.skills)],team:input.team,hours:input.hours};
}
export function rankCandidates(data, profile, excluded = [], now = new Date()) {
  const p=validateProfile(profile);
  return data.filter(c=>!excluded.includes(c.id) && !(c.eligibility==='graduate' && p.grade!=='研究生')
    && !(c.scheduleStatus==='verified'&&validDate(c.deadline)&&c.deadline<beijingDay(now)))
    .map(c=>({c,score:c.tags.filter(t=>p.interests.includes(t)).length*5+c.tags.filter(t=>p.skills.includes(t)).length*2
      +(p.goal==='explore'&&c.category==='基础类'?2:0)+(p.goal==='practice'&&c.tags.includes('design')?1:0)}))
    .sort((a,b)=>b.score-a.score||a.c.id-b.c.id).slice(0,18).map(x=>x.c);
}
export function basicPlan(data, profile, excluded=[]) {
  const candidates=rankCandidates(data,profile,excluded);
  const picks=candidates.slice(0,3);
  return {version:1,mode:'basic',createdAt:new Date().toISOString(),profile:{...profile},
    summary:'根据你选择的方向关联赛事，先核对资格，再用四周完成一次准备练习。此方案由基础规则生成。',
    recommendations:picks.map((c,i)=>({competitionId:c.id,role:['main','practice','backup'][i],
      reason:c.tags.some(t=>profile.interests.includes(t))?'赛事名称关联你选择的兴趣方向，可先了解具体赛道。':'作为探索候选，建议先阅读章程确认是否适合。',
      gaps:['当届参赛资格待确认','结合官方要求检查能力与组队需求'],pending:['当届报名及校内选拔时间待核验'],competition:c})),
    weeks:Array.from({length:4},(_,i)=>({week:i+1,tasks:picks.length?[{competitionId:picks[0].id,title:['阅读当届章程，核对资格与报名入口','整理任务要求，选择一个小练习','完成练习初稿，记录问题与资料来源','复盘练习成果，决定是否正式报名'][i],hours:Math.min(profile.hours,4)}]:[]}))};
}
export function validatePlan(raw,candidates,profile) {
  const fail=()=>{throw new Error('模型方案未通过校验，请重试或使用基础推荐');};
  const txt=(v,n=1200)=>typeof v==='string'&&v.trim().length>0&&v.length<=n;
  const strings=v=>Array.isArray(v)&&v.length<=8&&v.every(s=>txt(s,300));
  if(!raw||!txt(raw.summary)||!Array.isArray(raw.recommendations)||raw.recommendations.length<1||raw.recommendations.length>3||!Array.isArray(raw.weeks)||raw.weeks.length!==4)fail();
  const seen=new Set(),roles=new Set();
  const recommendations=raw.recommendations.map(r=>{
    const c=candidates.find(c=>c.id===r.competitionId);
    if(!c||seen.has(c.id)||!['main','practice','backup'].includes(r.role)||roles.has(r.role)||!txt(r.reason)||!strings(r.gaps)||!strings(r.pending))fail();
    seen.add(c.id);roles.add(r.role);
    return {competitionId:c.id,role:r.role,reason:r.reason,gaps:r.gaps,pending:[...new Set([...r.pending,'当届资格、赛道与校内截止时间须查官方通知'])],competition:c};
  });
  if(!roles.has('main'))fail();
  const weeks=raw.weeks.map((w,i)=>{
    if(w.week!==i+1||!Array.isArray(w.tasks)||!w.tasks.length||w.tasks.length>8)fail();
    const tasks=w.tasks.map(t=>{
      if(!seen.has(t.competitionId)||!txt(t.title,200)||!Number.isFinite(t.hours)||t.hours<=0||t.hours>profile.hours)fail();
      return {competitionId:t.competitionId,title:t.title,hours:t.hours};
    });
    if(tasks.reduce((s,t)=>s+t.hours,0)>profile.hours+1e-8)fail();
    return {week:i+1,tasks};
  });
  return {version:1,mode:'ai',createdAt:new Date().toISOString(),profile,summary:raw.summary,recommendations,weeks};
}
export function parseModelJson(content){
  if(typeof content!=='string'||content.length>100000)throw new Error('模型输出格式无效');
  const trimmed=content.trim();
  const fence=trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i);
  return JSON.parse(fence?fence[1]:trimmed);
}
export function calculateCredit(c,{college,cohort,award,scope,confirmed}) {
  const unavailable=reason=>({available:false,reason});
  if(college!=='土木学院'||cohort!=='2025')return unavailable('目前仅整理土木学院 2025 级参考规则，其他学院或年级暂不能核算。');
  if(!confirmed)return unavailable('请先核对原文并确认适用范围与团队认定条件。');
  if(!c||!Number.isInteger(award)||award<0||award>2)return unavailable('该奖项组合暂不能核算。');
  if(c.remarks?.trim())return unavailable('本赛事有特殊备注，请先核对赛道、奖项和成员认定条件，暂不自动计算。');
  const tier=scope==='school'?'四类':scope==='province'?'三类':c['tier'+(award+1)];
  const credit=SCORE_MATRIX[tier]?.[award];
  if(credit===undefined)return unavailable('缺少该层级的可靠折算依据。');
  return {available:true,tier,credit,version:RULE_VERSION,reason:'仅为单项奖项参考值，未处理团队分配、重复获奖及既有认定差值，不等于最终综测或推免加分。'};
}
export function validateTasks(tasks) {
  if(!Array.isArray(tasks)||tasks.length>2000)throw new Error('任务备份格式无效');
  return tasks.map(t=>{
    if(!t||typeof t.id!=='string'||t.id.length>180||typeof t.title!=='string'||!t.title.trim()||t.title.length>300||!Number.isInteger(t.competitionId)||!['normal','high'].includes(t.priority)||typeof t.done!=='boolean'||(t.due&&!validDate(t.due)))throw new Error('备份包含无效任务，未导入');
    return {id:t.id,title:t.title,competitionId:t.competitionId,priority:t.priority,done:t.done,due:t.due||'',week:Number.isInteger(t.week)?t.week:0};
  });
}
export function planToTasks(plan) {
  return plan.weeks.flatMap(w=>w.tasks.map((t,i)=>({id:`plan-${plan.createdAt}-${w.week}-${i}`,competitionId:t.competitionId,title:t.title,week:w.week,due:'',done:false,priority:plan.recommendations.find(r=>r.role==='main')?.competitionId===t.competitionId?'high':'normal'})));
}
export function calendarExport(tasks,data) {
  const esc=s=>String(s).replace(/\\/g,'\\\\').replace(/\r?\n/g,'\\n').replace(/,/g,'\\,').replace(/;/g,'\\;');
  const lines=['BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//XAUAT Compass//Plan//ZH','CALSCALE:GREGORIAN'];
  for(const t of tasks.filter(t=>validDate(t.due)&&!t.done)) {
    const c=data.find(c=>c.id===t.competitionId);const next=new Date(t.due+'T12:00:00Z');next.setUTCDate(next.getUTCDate()+1);
    lines.push('BEGIN:VEVENT',`UID:${encodeURIComponent(t.id)}@compass.local`,`DTSTAMP:${new Date().toISOString().replace(/[-:]/g,'').replace(/\.\d{3}/,'')}`,`DTSTART;VALUE=DATE:${t.due.replaceAll('-','')}`,`DTEND;VALUE=DATE:${next.toISOString().slice(0,10).replaceAll('-','')}`,`SUMMARY:${esc(t.title)}`,`DESCRIPTION:${esc(c?.name||'竞赛准备任务')}`,'END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  // Fold by UTF-8 octets, not JS character count (RFC 5545).
  return lines.map(line=>{let out='',part='',bytes=0;for(const ch of line){const size=new TextEncoder().encode(ch).length;if(bytes+size>73){out+=part+'\r\n ';part='';bytes=1;}part+=ch;bytes+=size;}return out+part;}).join('\r\n')+'\r\n';
}
