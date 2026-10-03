import {readFileSync,writeFileSync,existsSync,mkdirSync} from 'node:fs';
import {resolve} from 'node:path';
const origin='https://compass.lzso.top';
const credentialPath='runtime/deploy/cloudflare-secrets.json';
if(!existsSync(credentialPath))throw new Error('Missing local cloud administration credential. Keep it outside Git and recover it from the deployment administrator.');
const secret=JSON.parse(readFileSync(credentialPath,'utf8')).ADMIN_TOKEN;
if(typeof secret!=='string'||secret.length<32)throw new Error('Invalid administration credential.');
const command=process.argv[2]||'create';
const body=command==='list'?{action:'list'}:command==='revoke'?{action:'revoke',id:Number(process.argv[3])}:{action:'create',count:Number(command==='create'?process.argv[3]:command)||20};
if(body.action==='create'&&(!Number.isInteger(body.count)||body.count<1||body.count>50))throw new Error('Choose between 1 and 50 trial codes.');
const result=await fetch(origin+'/api/_admin/trials',{method:'POST',headers:{Authorization:`Bearer ${secret}`,'Content-Type':'application/json'},body:JSON.stringify(body)});
const payload=await result.json();if(!result.ok)throw new Error(payload.error||'Cloud trial operation failed.');
if(body.action==='list'){console.table(payload.trials);}
else if(body.action==='revoke'){console.log(JSON.stringify(payload));}
else {
  if(!Array.isArray(payload.codes)||payload.codes.length!==body.count)throw new Error('Unexpected trial batch response.');
  mkdirSync('runtime',{recursive:true});let batch=1;while(existsSync(`runtime/云端试用卡密-批次${batch}.txt`))batch++;
  const file=`runtime/云端试用卡密-批次${batch}.txt`;
  writeFileSync(file,`建大竞赛罗盘 · 云端试用卡密\n使用地址：${origin}\n每张每天 3 次有效生成，按北京时间更新。\n\n`+payload.codes.map((code,index)=>`${String(index+1).padStart(2,'0')}. ${code}`).join('\n')+'\n',{mode:0o600});
  console.log(JSON.stringify({created:payload.codes.length,file:resolve(file)}));
}
