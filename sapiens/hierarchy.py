"""One main orchestrator; every other Sapi belongs to its reporting tree."""
class Hierarchy:
    def __init__(self, service):
        self.service = service

    @property
    def main(self):
        rows = self.service.store.agents()
        return rows[0]['id'] if rows else None

    def repair(self):
        main = self.main
        root = self.service._agent(main)
        directory = root.corpora.directory()
        if directory[main]['parent'] is not None:
            root.corpora.register(main, parent=None, scope=directory[main]['scope'])
        for row in self.service.store.agents()[1:]:
            entry = root.corpora.directory()[row['id']]
            if entry['parent'] is None:
                root.corpora.register(row['id'], parent=main, scope=entry['scope'])

    def validate(self, agid, manager):
        from .service import APIError
        if agid == self.main:
            if manager is not None:
                raise APIError(400, 'The main orchestrator cannot have a manager')
            return None
        if manager is None:
            return self.main
        parent = self.service.orchestration.resolve(manager).agid
        directory = self.service._agent(self.main).corpora.directory()
        ancestor = parent
        while ancestor:
            if ancestor == agid:
                raise APIError(400, 'A Sapi cannot report to itself or one of its descendants')
            ancestor = directory[ancestor]['parent']
        return parent

    def assign(self, agent, parent):
        entry = agent.corpora.directory()[agent.agid]
        agent.corpora.register(agent.agid, parent=parent, scope=entry['scope'])
