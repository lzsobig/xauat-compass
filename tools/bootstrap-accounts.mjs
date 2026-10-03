import {readFileSync,writeFileSync,existsSync} from 'node:fs';
import {randomBytes} from 'node:crypto';
import {resolve} from 'node:path';
const origin='https://compass.lzso.top';
const secret=JSON.parse(readFileSync('runtime/deploy/cloudflare-secrets.json','utf8')).ADMIN_TOKEN;
const path='runtime/deploy/owner-account.json';
const recover=process.argv.includes('--recover');
let owner;
if(!recover&&existsSync(path))owner=JSON.parse(readFileSync(path,'utf8'));
else{owner={username:'compass_admin',password:'Cp!'+randomBytes(20).toString('base64url'),displayName:'项目管理员'};writeFileSync(path,JSON.stringify(owner),{mode:0o600});}
const response=await fetch(origin+(recover?'/api/_admin/recover-admin':'/api/_admin/bootstrap'),{method:'POST',headers:{Authorization:`Bearer ${secret}`,'Content-Type':'application/json'},body:JSON.stringify(owner)});
const result=await response.json();if(!response.ok&&response.status!==409)throw new Error(result.error||'Administrator setup failed.');
const login=await fetch(origin+'/api/auth/login',{method:'POST',headers:{Origin:origin,'Content-Type':'application/json'},body:JSON.stringify({username:owner.username,password:owner.password})});
if(!login.ok)throw new Error('Existing administrator credentials did not validate. No password was overwritten. Use --recover explicitly if recovery is intended.');
const file='runtime/管理员账号.txt';writeFileSync(file,`建大竞赛罗盘 · 管理员账号\n\n登录地址：${origin}/#admin\n用户名：${owner.username}\n初始密码：${owner.password}\n\n请只在本地查看并妥善保管。登录后可在“我的账号”修改密码，修改后本文件中的初始密码将不再有效。\n`,{mode:0o600});
console.log(JSON.stringify({verified:true,username:owner.username,credentialFile:resolve(file),recovered:recover}));
