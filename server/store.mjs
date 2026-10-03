import {DatabaseSync} from 'node:sqlite';
import {mkdirSync} from 'node:fs';
import {dirname} from 'node:path';
import {createHash,randomBytes} from 'node:crypto';
export const hash=value=>createHash('sha256').update(value).digest('hex');
export function openStore(path='runtime/compass.sqlite') {
  if(path!==':memory:')mkdirSync(dirname(path),{recursive:true});
  const db=new DatabaseSync(path);db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=3000;
    CREATE TABLE IF NOT EXISTS trials (id INTEGER PRIMARY KEY, code_hash TEXT UNIQUE NOT NULL, created_at TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1);
    CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, trial_id INTEGER NOT NULL, expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS calls (trial_id INTEGER NOT NULL, request_id TEXT NOT NULL, day TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, duration_ms INTEGER DEFAULT 0, tokens INTEGER DEFAULT 0, result TEXT, PRIMARY KEY(trial_id,request_id));
    CREATE TABLE IF NOT EXISTS feedback (id INTEGER PRIMARY KEY, trial_id INTEGER, kind TEXT NOT NULL, useful TEXT, note TEXT, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, trial_id INTEGER NOT NULL, name TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS attempts (ip_hash TEXT PRIMARY KEY, start INTEGER NOT NULL, count INTEGER NOT NULL);
  `);
  return db;
}
export function createTrial(db){const code='CP-'+randomBytes(12).toString('base64url');db.prepare('INSERT INTO trials(code_hash,created_at) VALUES (?,?)').run(hash(code),new Date().toISOString());return code;}
