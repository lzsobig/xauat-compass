CREATE TABLE IF NOT EXISTS trials (id INTEGER PRIMARY KEY, code_hash TEXT UNIQUE NOT NULL, created_at TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1);
CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, trial_id INTEGER NOT NULL, expires INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS calls (trial_id INTEGER NOT NULL, request_id TEXT NOT NULL, day TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, duration_ms INTEGER DEFAULT 0, tokens INTEGER DEFAULT 0, result TEXT, PRIMARY KEY(trial_id,request_id));
CREATE TABLE IF NOT EXISTS feedback (id INTEGER PRIMARY KEY, trial_id INTEGER, kind TEXT NOT NULL, useful TEXT, note TEXT, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, trial_id INTEGER NOT NULL, name TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS attempts (ip_hash TEXT PRIMARY KEY, start INTEGER NOT NULL, count INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS calls_day_status ON calls(day,status,created_at);
CREATE INDEX IF NOT EXISTS calls_trial_day_status ON calls(trial_id,day,status);
