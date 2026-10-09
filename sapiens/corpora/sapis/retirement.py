"""Reversible Sapi retirement; persistent history is never deleted."""
from sapiens.clock import utcnow
from sapiens.validation import APIError


class Lifecycle:
    def __init__(self, service):
        self.service = service

    def retired(self, agent):
        return bool(self.service.orchestration.settings(agent).get('retired_at'))

    def require_active(self, agent):
        if self.retired(agent):
            raise APIError(409, 'This Sapi is retired. Ask the chief to rehire it before assigning or running work.')

    def change(self, agid, retire, reason=''):
        with self.service._lock:
            agent = self.service._agent(agid)
            if agid == self.service.registry.main:
                raise APIError(400, 'The main orchestrator cannot be retired')
            if not isinstance(reason, str) or len(reason) > 500:
                raise APIError(400, 'reason must be text, at most 500 characters')
            settings = self.service.orchestration.settings(agent)
            if self.retired(agent) == retire:
                return dict(id=agid, retired=retire, changed=False)
            if retire:
                if any(agid in g['members'] and not g['archived'] for g in self.service.store.groups()):
                    raise APIError(409, 'Remove this Sapi from active Groups before retiring it')
                if any(c['addressedTo'] == agid and c['state'] == 'Queued'
                       for work in self.service.store.workloads() for c in work['calls']):
                    raise APIError(409, 'Cancel the accepted handoff before retiring this Sapi')
                if any(
                        j['status'] in {'queued', 'running', 'output_pending'} for j in agent.state['turns']):
                    raise APIError(409, 'Finish or cancel queued work before retiring this Sapi')
                if any(entry.get('parent') == agid and not self.retired(self.service._agent(child))
                       for child, entry in self.service.registry.directory().items()):
                    raise APIError(409, 'Reassign this Sapi\'s direct reports before retiring it')
                settings.update(retired_at=utcnow().isoformat(), retirement_reason=reason)
            else:
                settings.update(retired_at=None, retirement_reason='')
                parent = self.service.registry.directory()[agid].get('parent')
                if parent and self.retired(self.service._agent(parent)):
                    self.service.registry.assign(agent, self.service.registry.main)
            self.service.orchestration.save(agent, settings)
            self.service.store.events.record(agid, agid, 'sapi.retired' if retire else 'sapi.restored', dict(reason=reason))
            return dict(id=agid, retired=retire, changed=True)


    def catalog(self):
        result = []
        for row in self.service.store.agents():
            agent = self.service._agent(row['id'])
            settings = self.service.orchestration.settings(agent)
            if settings.get('retired_at'):
                result.append(dict(id=row['id'], name=row['name'], role=row['role'],
                    retired_at=settings['retired_at'], reason=settings.get('retirement_reason', ''),
                    manager=self.service.registry.directory().get(agent.agid, {}).get('parent')))
        return result
