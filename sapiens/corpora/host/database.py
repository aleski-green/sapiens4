"""SQLite metadata, authoritative workloads, and durable conversation projections."""
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
import json
import sqlite3

from sapiens.corpora.host.events import EventLog


def now():
    return datetime.now(timezone.utc).isoformat()


class Store:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.execute("PRAGMA journal_mode=WAL")
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if version not in (0, 1, 2, 3, 4, 5, 6, 7, 8):
                raise RuntimeError(f"Unsupported CORPORA schema: {version}")
            db.executescript("""
                CREATE TABLE IF NOT EXISTS scheduled_routines (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS system_pulse (
                    id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS pulse_calls (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS turn_details (
                    id TEXT PRIMARY KEY, value TEXT NOT NULL
                );
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
            db.execute('PRAGMA user_version=8')
        self.events = EventLog(self)

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
            previous = db.execute('SELECT value FROM groups WHERE id=?', (group['id'],)).fetchone()
            old = json.loads(previous[0]) if previous else {}
            known = {e['id'] for e in old.get('events', [])}
            for entry in group['events']:
                if entry['id'] not in known:
                    self.events.record([group['id'], *group['members'], *old.get('members', [])], group['id'],
                        'group.' + entry['action'].replace(' ', '.'), entry['detail'], actor=entry['actor'], db=db)
            db.execute('INSERT INTO groups VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',
                       (group['id'], json.dumps(group, ensure_ascii=False, allow_nan=False)))

    def save_workload(self, work):
        with self.connect() as db:
            previous = db.execute('SELECT value FROM workloads WHERE id=?', (work['workloadId'],)).fetchone()
            old = json.loads(previous[0]) if previous else {}
            call = work['calls'][-1]
            before = old.get('calls', [{}])[-1]
            if old and work['tracked'] and (not old.get('tracked') or
                    (call['state'], call['addressedTo']) != (before.get('state'), before.get('addressedTo'))):
                self.events.record([c['addressedTo'] for c in work['calls']], work['task']['taskId'],
                    'task.' + call['state'].lower(), dict(owner=call['addressedTo'], task=work['task'],
                    previous=before.get('state'), call=call['callId'], error=call.get('error')),
                    actor=(self.events.source.get()[0] if self.events.source.get()[1] or call['state'] == 'Cancelled'
                           else 'system' if call['state'] == 'Queued' else call['addressedTo']),
                    agency='chatInput' if call['state'] not in {'Queued', 'Cancelled'} else None, db=db)
            db.execute('INSERT INTO workloads VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',
                       (work['workloadId'], json.dumps(work, ensure_ascii=False, allow_nan=False)))

    def projected_turn(self, turn_id):
        with self.connect() as db:
            row = db.execute('SELECT * FROM turns WHERE id=?', (turn_id,)).fetchone()
            return dict(row) if row else None

    def project(self, agent, snapshot, outputs):
        with self.connect() as db:
            for turn in snapshot["turns"]:
                previous = db.execute('SELECT status FROM turns WHERE id=?', (turn['id'],)).fetchone()
                status = 'warning' if turn['status'] == 'done' and turn.get('warning') else turn['status']
                if previous is None or previous[0] != status:
                    origin = turn.get('origin') or {}
                    owners = [agent, *([origin['group']] if origin.get('group') else [])]
                    actor = ('system' if origin.get('routine') else origin.get('author', 'admin')) if status == 'queued' else agent
                    if status == 'cancelled':
                        actor = self.events.source.get()[0]
                    self.events.record(owners, turn['id'], 'call.' + status,
                        dict(previous=previous[0] if previous else None, origin=origin,
                             error=turn.get('error'), warning=turn.get('warning')),
                        actor=actor, agency='chatOutput' if turn.get('output_order') else turn.get('agency_kind'), db=db)
                details = {k: turn[k] for k in ('origin', 'batch_id', 'batch_members', 'agency_kind', 'slot', 'pulseId', 'output_at', 'output_order') if k in turn}
                db.execute('INSERT INTO turn_details VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',
                           (turn['id'], json.dumps(details)))
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
            details = {row['id']: json.loads(row['value']) for row in db.execute('SELECT * FROM turn_details')}
            for turn in turns:
                turn.update(details.get(turn['id'], {}))
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

    def pulse_state(self):
        with self.connect() as db:
            row = db.execute('SELECT value FROM system_pulse WHERE id=1').fetchone()
            return json.loads(row[0]) if row else {}

    def save_pulse_state(self, value):
        with self.connect() as db:
            db.execute('INSERT INTO system_pulse VALUES (1,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value',
                       (json.dumps(value),))

    def record_pulse_call(self, tick, agent, kind, slot, groups=()):
        record = dict(tick, agent=agent, agencyKind=kind, slot=slot, timestamp=now())
        with self.connect() as db:
            db.execute('INSERT INTO pulse_calls(value) VALUES (?)', (json.dumps(record),))
            self.events.record([agent, *groups], agent, 'pulse.dispatched', record, actor='system', agency=kind, db=db)
        return record

    def pulse_calls(self, agent=None, limit=500):
        with self.connect() as db:
            # Filter before limiting so a busy Sapi cannot hide another's history.
            rows = db.execute('SELECT value FROM pulse_calls ORDER BY sequence DESC')
            result = []
            for row in rows:
                value = json.loads(row[0])
                if agent is None or value['agent'] == agent:
                    result.append(value)
                    if len(result) == limit:
                        break
            return result

    def routines(self):
        with self.connect() as db:
            return [json.loads(row[0]) for row in db.execute('SELECT value FROM scheduled_routines ORDER BY sequence')]

    def save_routine(self, value):
        value = dict(value)
        with self.connect() as db:
            if 'id' not in value:
                sequence = db.execute("INSERT INTO scheduled_routines(value) VALUES ('{}')").lastrowid
                value['id'] = f'routine_sch_{sequence:05d}'
            db.execute('UPDATE scheduled_routines SET value=? WHERE sequence=?',
                       (json.dumps(value, ensure_ascii=False), int(value['id'].rsplit('_', 1)[1])))
        return value
