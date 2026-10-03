import {validateTasks,validateProfile,DEFAULT_PROFILE} from '../shared/core.js';
export const STORE_KEY='xauat_compass_v2';
export function readState(storage=localStorage,key=STORE_KEY) {
  try {const text=storage.getItem(key);if(!text)return {tasks:[],favorites:[],profile:{...DEFAULT_PROFILE},plan:null,syncRevision:0,syncDirty:false};
    const v=JSON.parse(text);if(v.version!==2)throw new Error('版本不支持');
    return {tasks:validateTasks(v.tasks),favorites:Array.isArray(v.favorites)?v.favorites.filter(Number.isInteger):[],profile:validateProfile(v.profile),plan:null,syncRevision:Number.isInteger(v.syncRevision)?v.syncRevision:0,syncDirty:v.syncDirty===true};
  }catch {return {tasks:[],favorites:[],profile:{...DEFAULT_PROFILE},plan:null,storageError:'本机数据读取失败，原数据已保留。请先导出原始备份或恢复有效备份，再继续保存。'};}
}
export function persistState(state,storage=localStorage,key=STORE_KEY) {
  if(state.storageError)throw new Error(state.storageError);
  storage.setItem(key,JSON.stringify({version:2,tasks:validateTasks(state.tasks),favorites:state.favorites,profile:state.profile,syncRevision:state.syncRevision||0,syncDirty:!!state.syncDirty}));
}
export function legacyArchives(storage=localStorage) {
  const result=[];
  for(let i=0;i<storage.length;i++){const key=storage.key(i);if(key==='xauat_compass_plan'||key?.startsWith('xauat_plan_'))result.push({key,label:key==='xauat_compass_plan'?'旧版访客计划':`本机旧档案 · ${key.slice(11,45)}`});}
  return result;
}
export function importLegacy(key,storage=localStorage) {
  if(!legacyArchives(storage).some(x=>x.key===key))throw new Error('找不到该旧档案');
  const list=JSON.parse(storage.getItem(key));if(!Array.isArray(list)||list.length>2000)throw new Error('旧档案格式无效，未修改数据');
  const tasks=validateTasks(list.map(p=>({id:`legacy-${key}-${p.id}`,competitionId:Number(p.id),title:'核对当届资格与报名要求',priority:'normal',done:false,due:'',week:0})));
  let profile=null;
  const profileText=storage.getItem(key.replace('xauat_plan_','xauat_profile_'));
  if(profileText){const p=JSON.parse(profileText);profile={...DEFAULT_PROFILE,grade:({freshman:'大一',sophomore:'大二',junior:'大三',senior:'大四'})[p.grade]||'大一',interests:({civil:['engineering'],arch:['design'],cs:['code'],mech:['engineering'],mgmt:['business'],cross:[]})[p.major]||[],skills:(p.skills||[]).map(x=>({coding:'code',structure:'hardware',presentation:'present'})[x]||x).filter(x=>['math','code','design','writing','hardware','present'].includes(x))};profile=validateProfile(profile);}
  return {tasks,profile};
}
export function mergeTasks(existing,incoming){const ids=new Set(existing.map(t=>t.id));return [...existing,...incoming.filter(t=>{if(ids.has(t.id))return false;ids.add(t.id);return true;})];}
