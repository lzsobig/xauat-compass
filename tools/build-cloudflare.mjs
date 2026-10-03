import {copyFileSync,mkdirSync,readdirSync} from 'node:fs';
import {resolve} from 'node:path';
import './build.mjs';
const destination=resolve('dist/cloudflare');mkdirSync(destination,{recursive:true});
copyFileSync('index.html',resolve(destination,'index.html'));
for(const folder of ['public','shared']){
  mkdirSync(resolve(destination,folder),{recursive:true});
  for(const file of readdirSync(folder).filter(file=>/\.(js|css|svg)$/.test(file)))copyFileSync(resolve(folder,file),resolve(destination,folder,file));
}
mkdirSync(resolve(destination,'sources'),{recursive:true});
copyFileSync('附件：西安建筑科技大学学生学科竞赛分级分类一览表（2025）.pdf',resolve(destination,'sources/catalog.pdf'));
copyFileSync('土木院 2025 级本科生学分认定细则（试行）.pdf',resolve(destination,'sources/civil.pdf'));
console.log('Cloudflare assets prepared without secrets or runtime data.');
