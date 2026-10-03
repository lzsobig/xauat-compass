import {openStore} from '../server/store.mjs';
import {mkdirSync,writeFileSync} from 'node:fs';
const db=openStore(process.env.DB_PATH||'runtime/compass.sqlite');
const sqlValue=value=>value===null?'NULL':typeof value==='number'?String(value):"'"+String(value).replaceAll("'","''")+"'";
const lines=[];
const payload={};
for(const table of ['trials','calls','feedback','events']){
  const rows=db.prepare(`SELECT * FROM ${table}`).all();
  payload[table]=rows.map(row=>({...row,...(table==='calls'&&row.status==='running'?{status:'interrupted'}:{})}));
  for(const row of rows){const clean={...row};if(table==='calls'&&clean.status==='running')clean.status='interrupted';lines.push(`INSERT OR IGNORE INTO ${table} (${Object.keys(clean).join(',')}) VALUES (${Object.values(clean).map(sqlValue).join(',')});`);}
}
mkdirSync('runtime/deploy',{recursive:true});writeFileSync('runtime/deploy/seed.sql',lines.join('\n')+'\n');
writeFileSync('runtime/deploy/seed.json',JSON.stringify(payload));
console.log(JSON.stringify({exportedStatements:lines.length,trials:db.prepare('SELECT count(*) n FROM trials WHERE active=1').get().n}));db.close();
