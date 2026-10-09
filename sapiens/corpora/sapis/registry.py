"""Sapi registration and reporting relationships, with one hierarchy check."""
import json

from sapiens.files import atomic_json, file_lock
from sapiens.validation import APIError


class Registry:
    def __init__(self, service):
        self.service = service
        self.root = service.root / 'agentpy/corpora'

    def directory(self):
        path = self.root / 'directory.json'
        return json.loads(path.read_bytes()) if path.exists() else {}

    @staticmethod
    def check_parent(directory, agid, parent):
        if parent is not None and parent not in directory:
            raise APIError(400, 'Parent Sapi must be registered first')
        seen = {agid}
        while parent:
            if parent in seen:
                raise APIError(400, 'A Sapi cannot report to itself or one of its descendants')
            seen.add(parent)
            parent = directory[parent]['parent']

    def register(self, agid, *, parent=None, scope=''):
        with file_lock(self.root / '.directory.lock'):
            directory = self.directory()
            self.check_parent(directory, agid, parent)
            directory[agid] = dict(parent=parent, scope=scope)
            atomic_json(self.root / 'directory.json', directory)

    @property
    def main(self):
        rows = self.service.store.agents()
        return rows[0]['id'] if rows else None

    def repair(self):
        main = self.main
        directory = self.directory()
        if directory[main]['parent'] is not None:
            self.register(main, parent=None, scope=directory[main]['scope'])
        for row in self.service.store.agents()[1:]:
            entry = self.directory()[row['id']]
            if entry['parent'] is None:
                self.register(row['id'], parent=main, scope=entry['scope'])

    def validate(self, agid, manager):
        if agid == self.main:
            if manager is not None:
                raise APIError(400, 'The main orchestrator cannot have a manager')
            return None
        if manager is None:
            return self.main
        parent = self.service.orchestration.resolve(manager).agid
        directory = self.directory()
        self.check_parent(directory, agid, parent)
        return parent

    def assign(self, agent, parent):
        entry = self.directory()[agent.agid]
        self.register(agent.agid, parent=parent, scope=entry['scope'])
        if entry['parent'] != parent:
            self.service.store.events.record(agent.agid, agent.agid, 'sapi.manager.changed',
                dict(previous=entry['parent'], manager=parent))
