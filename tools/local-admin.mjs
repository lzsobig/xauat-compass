import {readFileSync} from 'node:fs';
import {openStore} from '../server/store.mjs';
import {databaseAdapter} from '../server/index.mjs';
import {bootstrapAdmin} from '../shared/accounts.js';
const credentials=JSON.parse(readFileSync('runtime/deploy/owner-account.json','utf8'));
const db=openStore(process.env.DB_PATH||'runtime/compass.sqlite');
try{const user=await bootstrapAdmin(credentials,{...process.env,DB:databaseAdapter(db)});console.log(JSON.stringify({created:true,username:user.username,environment:'local'}));}
catch(error){if(error.status===409)console.log('Local administrator already exists; its password was not overwritten.');else throw error;}
finally{db.close();}
