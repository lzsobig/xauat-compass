import {DurableObject} from 'cloudflare:workers';
import schema from './schema.sql';
import {handleApi} from './worker.mjs';
import {sqliteAdapter} from './sqlite-adapter.js';
import {migrateAccountSchema} from '../shared/account-schema.js';
import {bootstrapAdmin,recoverAdmin} from '../shared/accounts.js';

const response=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
const fields={trials:['id','code_hash','created_at','active'],calls:['trial_id','request_id','day','status','created_at','duration_ms','tokens','result'],feedback:['id','trial_id','kind','useful','note','created_at'],events:['id','trial_id','name','created_at']};
async function digest(value){return [...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)))].map(x=>x.toString(16).padStart(2,'0')).join('');}
async function adminBody(request){const text=await request.text();if(new TextEncoder().encode(text).length>256000)throw new Error('Import payload too large');return JSON.parse(text);}

export class CompassStore extends DurableObject {
  constructor(ctx,env){super(ctx,env);ctx.storage.sql.exec(schema);migrateAccountSchema(query=>ctx.storage.sql.exec(query).toArray());this.db=sqliteAdapter(ctx.storage);this.env=env;}
  async fetch(request){
    try{
      const path=new URL(request.url).pathname;
      if(path.startsWith('/api/_admin/')){
        if(!this.env.ADMIN_TOKEN||request.headers.get('Authorization')!==`Bearer ${this.env.ADMIN_TOKEN}`)return response({error:'接口不存在'},404);
        if(request.method!=='POST')return response({error:'不支持的请求方法'},405);
        const body=await adminBody(request);
        if(path==='/api/_admin/bootstrap')return response({user:await bootstrapAdmin(body,{...this.env,DB:this.db})});
        if(path==='/api/_admin/recover-admin')return response(await recoverAdmin(body,{...this.env,DB:this.db}));
        if(path==='/api/_admin/import'){
          const statements=[];
          for(const [table,columns] of Object.entries(fields)){
            const rows=body[table]||[];if(!Array.isArray(rows)||rows.length>3000)throw new Error('Invalid import');
            for(const row of rows){if(columns.some(key=>!(key in row)))throw new Error('Missing import field');statements.push(this.db.prepare(`INSERT OR IGNORE INTO ${table} (${columns.join(',')}) VALUES (${columns.map(()=>'?').join(',')})`).bind(...columns.map(key=>row[key])));}
          }
          await this.db.batch(statements);
          return response({ok:true,imported:statements.length,activeTrials:(await this.db.prepare('SELECT count(*) n FROM trials WHERE active=1').first()).n});
        }
        if(path==='/api/_admin/trials'){
          if(body.action==='list')return response({trials:this.ctx.storage.sql.exec('SELECT id,created_at,active FROM trials ORDER BY id').toArray()});
          if(body.action==='revoke'){
            if(!Number.isInteger(body.id)||body.id<1)throw new Error('Invalid trial id');
            const result=await this.db.prepare('UPDATE trials SET active=0 WHERE id=?').bind(body.id).run();
            return response({ok:true,changed:result.meta.changes});
          }
          if(!Number.isInteger(body.count)||body.count<1||body.count>50)throw new Error('Invalid count');
          const codes=[];for(let i=0;i<body.count;i++){
            const code='CP-'+[...crypto.getRandomValues(new Uint8Array(12))].map(x=>x.toString(16).padStart(2,'0')).join('');
            await this.db.prepare('INSERT INTO trials(code_hash,created_at) VALUES(?,?)').bind(await digest(code),new Date().toISOString()).run();codes.push(code);
          }
          return response({codes});
        }
        return response({error:'接口不存在'},404);
      }
      return await handleApi(request,{...this.env,DB:this.db},this.ctx);
    }catch(error){return response({error:error.status?error.message:'输入内容无效，请检查后重试'},error.status||400);}
  }
}

export default {
  async fetch(request,env){
    if(new URL(request.url).pathname.startsWith('/api/'))return env.STORE.get(env.STORE.idFromName('compass-production')).fetch(request);
    const asset=await env.ASSETS.fetch(request),output=new Response(asset.body,asset);
    output.headers.set('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
    output.headers.set('X-Content-Type-Options','nosniff');output.headers.set('Referrer-Policy','no-referrer');return output;
  }
};
