import {openStore,createTrial} from '../server/store.mjs';
const db=openStore(process.env.DB_PATH||'runtime/compass.sqlite');
const command=process.argv[2]||'create';
if(command==='list')console.table(db.prepare('SELECT id,created_at,active FROM trials ORDER BY id').all());
else if(command==='revoke'){
  const id=Number(process.argv[3]);if(!Number.isInteger(id)||id<1)throw new Error('Usage: npm run trial -- revoke <id>');
  const result=db.prepare('UPDATE trials SET active=0 WHERE id=?').run(id);console.log(`Revoked ${result.changes} trial.`);
}else if(command==='create'||/^\d+$/.test(command)){
  const n=Math.max(1,Math.min(50,Number(command==='create'?process.argv[3]:command)||1));
  for(let i=0;i<n;i++)console.log(createTrial(db));
}else throw new Error('Usage: npm run trial -- [create <count> | list | revoke <id>]');
db.close();
