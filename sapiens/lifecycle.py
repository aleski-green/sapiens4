"""Reversible Sapi retirement; persistent history is never deleted."""
from .clock import utcnow
from .validation import APIError


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
            if agid == self.service.hierarchy.main:
                raise APIError(400, 'The main orchestrator cannot be retired')
            if not isinstance(reason, str) or len(reason) > 500:
                raise APIError(400, 'reason must be text, at most 500 characters')
            settings = self.service.orchestration.settings(agent)
            if self.retired(agent) == retire:
                return dict(id=agid, retired=retire, changed=False)
            if retire:
                if agid in self.service._background or any(
                        j['status'] in {'queued', 'running'} for j in agent.state['jobs']):
                    raise APIError(409, 'Finish or cancel queued work before retiring this Sapi')
                if any(entry.get('parent') == agid and not self.retired(self.service._agent(child))
                       for child, entry in agent.corpora.directory().items()):
                    raise APIError(409, 'Reassign this Sapi\'s direct reports before retiring it')
                settings.update(retired_at=utcnow().isoformat(), retirement_reason=reason,
                                enabled=False, next_check=None, monitor_team=False,
                                consolidate_requested=False)
            else:
                settings.update(retired_at=None, retirement_reason='')
                parent = agent.corpora.directory()[agid].get('parent')
                if parent and self.retired(self.service._agent(parent)):
                    self.service.hierarchy.assign(agent, self.service.hierarchy.main)
            # The retired flag is authoritative even if the process exits before
            # recurring definitions are paused. Restoring also keeps them paused.
            if not retire:
                self.pause_recurring(agent)
            self.service.orchestration.save(agent, settings)
            if retire:
                self.pause_recurring(agent)
            self.service.store.event(agid, 'retired' if retire else 'restored', reason or
                                     ('Sapi retired; history preserved' if retire else 'Sapi restored'))
            return dict(id=agid, retired=retire, changed=True)

    def pause_recurring(self, agent):
        definitions = self.service.work.read(agent)
        for definition in definitions:
            definition['enabled'] = False
        self.service.work.save(agent, definitions)

    def catalog(self):
        result = []
        for row in self.service.store.agents():
            agent = self.service._agent(row['id'])
            settings = self.service.orchestration.settings(agent)
            if settings.get('retired_at'):
                result.append(dict(id=row['id'], name=row['name'], role=row['role'],
                    retired_at=settings['retired_at'], reason=settings.get('retirement_reason', ''),
                    manager=agent.corpora.directory().get(agent.agid, {}).get('parent'),
                    open_tasks=len(agent.state['tasks']), memory_entries=len(agent.memx)))
        return result
