import {openStore} from '../server/store.mjs';
const db=openStore(process.env.DB_PATH||'runtime/compass.sqlite');
console.log(JSON.stringify({calls:db.prepare('SELECT day,status,count(*) count,round(avg(duration_ms)) mean_ms,sum(tokens) tokens FROM calls GROUP BY day,status').all(),events:db.prepare('SELECT name,count(*) count FROM events GROUP BY name').all(),feedback:db.prepare('SELECT kind,useful,count(*) count FROM feedback GROUP BY kind,useful').all()},null,2));db.close();
