"""Small, bounded event journal shared by existing mutation paths."""
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import datetime, timezone
import json


class EventLog:
    def __init__(self, store):
        self.store = store
        self.source = ContextVar('event_source', default=('admin', None))
        with store.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS activity_events (
                    id INTEGER PRIMARY KEY, owner TEXT NOT NULL, timestamp TEXT NOT NULL,
                    actor TEXT NOT NULL, entity TEXT NOT NULL, event TEXT NOT NULL,
                    agency TEXT, details TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS activity_events_owner ON activity_events(owner, id);
            ''')

    @contextmanager
    def context(self, actor, agency=None):
        token = self.source.set((actor, agency))
        try:
            yield
        finally:
            self.source.reset(token)

    def record(self, owners, entity, event, details, *, actor=None, agency=None, db=None):
        if db is None:
            with self.store.connect() as db:
                return self.record(owners, entity, event, details, actor=actor, agency=agency, db=db)
        source, kind = self.source.get()
        actor = actor or source
        owners = {owners} if isinstance(owners, str) else set(owners)
        if actor.startswith('sapi_'):
            owners.add(actor)
        timestamp = datetime.now(timezone.utc).isoformat(timespec='milliseconds')
        for owner in sorted(owners):
            db.execute('INSERT INTO activity_events(owner,timestamp,actor,entity,event,agency,details) VALUES (?,?,?,?,?,?,?)',
                       (owner, timestamp, actor, entity, event, agency or kind,
                        json.dumps(details, ensure_ascii=False, allow_nan=False)))
            db.execute('DELETE FROM activity_events WHERE owner=? AND id NOT IN '
                       '(SELECT id FROM activity_events WHERE owner=? ORDER BY id DESC LIMIT 100)', (owner, owner))

    def snapshot(self, owner=None):
        with self.store.connect() as db:
            rows = db.execute('SELECT * FROM activity_events' + (' WHERE owner=?' if owner else '') +
                              ' ORDER BY id DESC', (owner,) if owner else ())
            result = {}
            for row in rows:
                value = dict(row)
                value['details'] = json.loads(value['details'])
                result.setdefault(value.pop('owner'), []).append(value)
            return result
