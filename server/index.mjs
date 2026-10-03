import {createServer} from 'node:http';
import {readFileSync,existsSync} from 'node:fs';
import {resolve,extname} from 'node:path';
import {pathToFileURL} from 'node:url';
import {openStore} from './store.mjs';
import {sqliteAdapter} from '../cloudflare/sqlite-adapter.js';
import {handleApi} from '../cloudflare/worker.mjs';

const ROOT=resolve(import.meta.dirname,'..');
const security={'X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','Cache-Control':'no-store','Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"};
export function databaseAdapter(db){
 return sqliteAdapter({sql:{exec(query,...values){const statement=db.prepare(query);const rows=statement.columns().length?statement.all(...values):(statement.run(...values),[]);return {toArray:()=>rows};}},transactionSync(fn){db.exec('BEGIN');try{const result=fn();db.exec('COMMIT');return result;}catch(error){db.exec('ROLLBACK');throw error;}}});
}
export function createApp(options={}){
 const settings=options.env||process.env,db=options.db||openStore(settings.DB_PATH||resolve(ROOT,'runtime/compass.sqlite'));
 db.prepare("UPDATE calls SET status='interrupted' WHERE status='running'").run();
 const env={...settings,APP_ORIGIN:settings.APP_ORIGIN||`http://127.0.0.1:${settings.PORT||4173}`,DB:databaseAdapter(db),UPSTREAM_FETCH:options.fetch||fetch};
 const server=createServer(async(req,res)=>{
  for(const [name,value]of Object.entries(security))res.setHeader(name,value);
  try{
   const url=new URL(req.url,'http://local');
   if(url.pathname.startsWith('/api/')){
    const chunks=[];let bytes=0;
    for await(const chunk of req){bytes+=chunk.length;if(bytes>512000)throw Object.assign(new Error('请求内容过长'),{status:413});chunks.push(chunk);}
    const controller=new AbortController();
    const headers=new Headers();for(const [name,value]of Object.entries(req.headers)){if(value!==undefined)headers.set(name,Array.isArray(value)?value.join(','):value);}
    headers.set('cf-connecting-ip',req.socket.remoteAddress||'local');
    const body=Buffer.concat(chunks);
    const request=new Request(env.APP_ORIGIN+url.pathname+url.search,{method:req.method,headers,signal:controller.signal,...(!['GET','HEAD'].includes(req.method)?{body}: {})});
    const ctx={waitUntil(job){job.catch(()=>console.error('API background task failed'));}};
    const response=await handleApi(request,env,ctx);
    const outputHeaders={};for(const [name,value]of response.headers)if(name!=='set-cookie')outputHeaders[name]=value;
    const cookies=response.headers.getSetCookie();if(cookies.length)outputHeaders['set-cookie']=cookies;
    res.writeHead(response.status,outputHeaders);
    const reader=response.body?.getReader();
    const disconnect=()=>{if(!res.writableEnded){controller.abort();reader?.cancel().catch(()=>{});}};res.on('close',disconnect);
    try{if(reader)while(true){const {done,value}=await reader.read();if(done)break;if(!res.write(value))await new Promise(resolve=>{res.once('drain',resolve);res.once('close',resolve);});}res.end();}finally{res.off('close',disconnect);}
    return;
   }
   if(!['GET','HEAD'].includes(req.method))throw Object.assign(new Error('不支持的请求方法'),{status:405});
   const sources={'/sources/catalog.pdf':'附件：西安建筑科技大学学生学科竞赛分级分类一览表（2025）.pdf','/sources/civil.pdf':'土木院 2025 级本科生学分认定细则（试行）.pdf'};
   let file;
   if(url.pathname==='/'||url.pathname==='/index.html')file=resolve(ROOT,'index.html');
   else if(sources[url.pathname])file=resolve(ROOT,sources[url.pathname]);
   else if(/^\/public\/[a-zA-Z0-9_-]+\.(js|css|svg)$/.test(url.pathname)||url.pathname==='/shared/core.js')file=resolve(ROOT,'.'+url.pathname);
   if(!file||!existsSync(file))throw Object.assign(new Error('页面不存在'),{status:404});
   const type={'.html':'text/html','.css':'text/css','.js':'text/javascript','.svg':'image/svg+xml','.pdf':'application/pdf'}[extname(file)],buffer=readFileSync(file);
   res.writeHead(200,{'Content-Type':type+'; charset=utf-8','Content-Length':buffer.length});res.end(req.method==='HEAD'?undefined:buffer);
  }catch(error){if(!res.headersSent){res.writeHead(error.status||400,{'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify({error:error.status?error.message:'输入内容无效，请检查后重试'}));}else res.end();}
 });
 return {server,db};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){const {server}=createApp();server.listen(Number(process.env.PORT)||4173,process.env.HOST||'127.0.0.1',()=>console.log(`Compass listening at ${process.env.APP_ORIGIN||'http://127.0.0.1:4173'}`));}
