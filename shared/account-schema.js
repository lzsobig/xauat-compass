export const ACCOUNT_TABLES = `
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE COLLATE NOCASE,
  display_name TEXT NOT NULL, password_hash TEXT NOT NULL, password_salt TEXT NOT NULL,
  password_iterations INTEGER NOT NULL, role TEXT NOT NULL DEFAULT 'user',
  status TEXT NOT NULL DEFAULT 'active', daily_grant INTEGER NOT NULL DEFAULT 0,
  must_change_password INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, last_login_at TEXT
);
CREATE TABLE IF NOT EXISTS user_sessions (token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL, expires INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS user_sessions_user ON user_sessions(user_id);
CREATE TABLE IF NOT EXISTS user_workspaces (user_id INTEGER PRIMARY KEY, payload TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS account_audit (id INTEGER PRIMARY KEY, actor_id INTEGER, action TEXT NOT NULL, target_id INTEGER, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS user_events (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, name TEXT NOT NULL, created_at TEXT NOT NULL);
`;
export function migrateAccountSchema(exec){
  exec(ACCOUNT_TABLES);
  const columns=new Set(exec('PRAGMA table_info(trials)').map(row=>row.name));
  for(const [name,definition] of [['owner_user_id','INTEGER'],['daily_limit','INTEGER NOT NULL DEFAULT 3'],['kind',"TEXT NOT NULL DEFAULT 'redeem'"],['claimed_at','TEXT']]){
    if(!columns.has(name))exec(`ALTER TABLE trials ADD COLUMN ${name} ${definition}`);
  }
  exec('CREATE INDEX IF NOT EXISTS trials_owner ON trials(owner_user_id,active)');
  for(const table of ['calls','feedback']){
    const existing=new Set(exec(`PRAGMA table_info(${table})`).map(row=>row.name));
    if(!existing.has('user_id'))exec(`ALTER TABLE ${table} ADD COLUMN user_id INTEGER`);
  }
  exec('CREATE UNIQUE INDEX IF NOT EXISTS calls_user_request ON calls(user_id,request_id)');
}
