"""SQLite metadata, authoritative workloads, and durable conversation projections."""
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
import json
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
            if version not in (0, 1, 2, 3, 4, 5):
                raise RuntimeError(f"Unsupported CORPORA schema: {version}")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS agents (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL,
                    color TEXT NOT NULL, face TEXT NOT NULL, created TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS turns (
                    id TEXT PRIMARY KEY, agent TEXT NOT NULL REFERENCES agents(id),
                    flow TEXT NOT NULL, input TEXT NOT NULL, status TEXT NOT NULL,
                    output TEXT, error TEXT, tokens INTEGER NOT NULL, created TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS turns_agent ON turns(agent, created);
                CREATE TABLE IF NOT EXISTS preferences (
                    id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS attachments (
                    id TEXT PRIMARY KEY, agent TEXT NOT NULL REFERENCES agents(id),
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS message_inputs (
                    job TEXT PRIMARY KEY, text TEXT NOT NULL, attachments TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS workloads (
                    id TEXT PRIMARY KEY, value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS group_attachments (
                    id TEXT PRIMARY KEY, agent TEXT NOT NULL REFERENCES groups(id), value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS groups (
                    id TEXT PRIMARY KEY, value TEXT NOT NULL
                );
            """)
            if version in (1, 2):
                db.execute("INSERT OR IGNORE INTO turns SELECT * FROM jobs WHERE flow IN ('chat','computer')")
            preferences = db.execute('SELECT value FROM preferences WHERE id=1').fetchone()
            if preferences:
                value = json.loads(preferences[0])
                if value.get('panel') == 'mindmap':
                    value['panel'] = 'notes'
                elif value.get('panel') in {'cron', 'log'}:
                    value['panel'] = 'chat'
                value.pop('work_views', None)
                db.execute('UPDATE preferences SET value=? WHERE id=1', (json.dumps(value),))
            db.execute('PRAGMA user_version=5')

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

    def update_avatar(self, agid, row):
        with self.connect() as db:
            db.execute("UPDATE agents SET face=:face, color=:color WHERE id=:id", {**row, "id": agid})

    def attachment(self, row):
        with self.connect() as db:
            table = 'group_attachments' if row['agent'].startswith('group_') else 'attachments'
            db.execute(f"INSERT INTO {table} VALUES (?,?,?)", (row["id"], row["agent"], json.dumps(row)))

    def attachments(self, agid):
        with self.connect() as db:
            table = 'group_attachments' if agid.startswith('group_') else 'attachments'
            return [json.loads(row[0]) for row in db.execute(f"SELECT value FROM {table} WHERE agent=?", (agid,))]

    def message(self, turn, text, attachments):
        with self.connect() as db:
            db.execute("INSERT OR IGNORE INTO message_inputs VALUES (?,?,?)", (turn, text, json.dumps(attachments)))

    def workloads(self):
        with self.connect() as db:
            return [json.loads(row[0]) for row in db.execute('SELECT value FROM workloads ORDER BY rowid')]

    def groups(self):
        with self.connect() as db:
            return [json.loads(row[0]) for row in db.execute('SELECT value FROM groups ORDER BY rowid')]

    def save_group(self, group):
        with self.connect() as db:
            db.execute('INSERT INTO groups VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',
                       (group['id'], json.dumps(group, ensure_ascii=False, allow_nan=False)))

    def save_workload(self, work):
        with self.connect() as db:
            db.execute('INSERT INTO workloads VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',
                       (work['workloadId'], json.dumps(work, ensure_ascii=False, allow_nan=False)))

    def projected_turn(self, turn_id):
        with self.connect() as db:
            row = db.execute('SELECT * FROM turns WHERE id=?', (turn_id,)).fetchone()
            return dict(row) if row else None

    def project(self, agent, snapshot, outputs):
        with self.connect() as db:
            for turn in snapshot["turns"]:
                db.execute("""INSERT INTO turns VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET status=excluded.status,
                    output=COALESCE(excluded.output,turns.output), error=excluded.error""",
                           (turn["id"], agent, turn["flow"], turn["input"], "warning" if turn["status"] == "done" and turn.get("warning") else turn["status"],
                            outputs.get(turn["id"]), turn.get("error") or turn.get("warning"), 0, turn["created"]))

    def snapshot(self, agent=None):
        with self.connect() as db:
            query = "SELECT * FROM turns" + (" WHERE agent=?" if agent else "")
            turns = [dict(row) for row in db.execute(query + " ORDER BY created, id", (agent,) if agent else ())]
            messages = {row["job"]: row for row in db.execute("SELECT * FROM message_inputs")}
            for turn in turns:
                turn.pop("tokens", None)  # Legacy SQL column stays archived, not exposed.
                message = messages.get(turn["id"])
                turn["attachments"] = json.loads(message["attachments"]) if message else []
                if message:
                    turn["input"] = message["text"]
            preferences = db.execute("SELECT value FROM preferences WHERE id=1").fetchone()
        return {"agents": self.agents(), "turns": turns,
                "preferences": json.loads(preferences[0]) if preferences else {}}

    def read_preferences(self):
        with self.connect() as db:
            row = db.execute("SELECT value FROM preferences WHERE id=1").fetchone()
        return json.loads(row[0]) if row else {}

    def preferences(self, value):
        with self.connect() as db:
            db.execute("INSERT INTO preferences VALUES (1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value",
                       (json.dumps(value, ensure_ascii=False, allow_nan=False),))
