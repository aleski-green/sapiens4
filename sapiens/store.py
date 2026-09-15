"""SQLite UI metadata and durable projections. AgentPy owns runtime state."""
from contextlib import contextmanager
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3


def now():
    return datetime.now(timezone.utc).isoformat()


class Store:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if version not in (0, 1):
                raise RuntimeError(f"Unsupported CORPORA schema: {version}")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS agents (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL,
                    color TEXT NOT NULL, face TEXT NOT NULL, created TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, agent TEXT NOT NULL REFERENCES agents(id),
                    flow TEXT NOT NULL, input TEXT NOT NULL, status TEXT NOT NULL,
                    output TEXT, error TEXT, tokens INTEGER NOT NULL, created TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS jobs_agent ON jobs(agent, created);
                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent TEXT NOT NULL REFERENCES agents(id), job TEXT,
                    source_key TEXT UNIQUE, kind TEXT NOT NULL,
                    detail TEXT NOT NULL, time TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS events_agent ON events(agent, id);
                CREATE TABLE IF NOT EXISTS preferences (
                    id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL
                );
                PRAGMA user_version=1;
            """)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def agents(self):
        with self.connect() as db:
            return [dict(row) for row in db.execute("SELECT * FROM agents ORDER BY created, id")]

    def add_agent(self, row):
        with self.connect() as db:
            db.execute("INSERT INTO agents VALUES (:id,:name,:role,:color,:face,:created)", row)

    def update_agent(self, agid, row):
        with self.connect() as db:
            db.execute("UPDATE agents SET name=:name, role=:role WHERE id=:id", {**row, "id": agid})

    def event(self, agent, kind, detail, job=None, source_key=None, time=None):
        with self.connect() as db:
            db.execute("""INSERT OR IGNORE INTO events
                (agent,job,source_key,kind,detail,time) VALUES (?,?,?,?,?,?)""",
                       (agent, job, source_key, kind, str(detail), time or now()))

    def project(self, agent, snapshot, outputs):
        with self.connect() as db:
            for job in snapshot["jobs"]:
                db.execute("""INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET status=excluded.status,
                    output=COALESCE(excluded.output,jobs.output), error=excluded.error,
                    tokens=excluded.tokens""",
                           (job["id"], agent, job["flow"], job["task"], job["status"],
                            outputs.get(job["id"]), job.get("error"), job["tokens"], job["created"]))
            for event in snapshot["events"]:
                db.execute("""INSERT OR IGNORE INTO events
                    (agent,job,source_key,kind,detail,time) VALUES (?,?,?,?,?,?)""",
                           (agent, event.get("job"), f"{agent}:{event['sequence']}",
                            event["kind"], json.dumps(event), event["time"]))

    def snapshot(self, after=0, agent=None):
        with self.connect() as db:
            query = "SELECT * FROM jobs" + (" WHERE agent=?" if agent else "")
            jobs = [dict(row) for row in db.execute(query + " ORDER BY created, id", (agent,) if agent else ())]
            events = [dict(row) for row in db.execute(
                "SELECT * FROM events WHERE id>? ORDER BY id LIMIT 500", (after,))]
            latest = db.execute("SELECT COALESCE(MAX(id),0) FROM events").fetchone()[0]
            preferences = db.execute("SELECT value FROM preferences WHERE id=1").fetchone()
        return {"agents": self.agents(), "jobs": jobs, "events": events,
                "cursor": events[-1]["id"] if events else after, "latest_cursor": latest,
                "preferences": json.loads(preferences[0]) if preferences else {}}

    def preferences(self, value):
        with self.connect() as db:
            db.execute("INSERT INTO preferences VALUES (1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value",
                       (json.dumps(value, ensure_ascii=False, allow_nan=False),))
