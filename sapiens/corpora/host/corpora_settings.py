"""Durable corpora identity and execution state, independent of client connections."""
import json
import platform
import time

from sapiens.files import atomic_json
from sapiens.prompts import prompt
from sapiens.validation import APIError


class CorporaSettings:
    def __init__(self, service):
        self.service = service
        self.path = service.root / 'corpora-settings.json'
        self.value = json.loads(self.path.read_text()) if self.path.exists() else {
            'name': None, 'device': platform.node() or 'This computer', 'scope': '',
            'status': 'active', 'revision': 1, 'operations': {}}

    def save(self):
        atomic_json(self.path, self.value)

    def identity(self):
        service = self.service
        main = next((a for a in service.store.agents() if a['id'] == service.registry.main), {})
        return dict(id=service.corpora_id, name=self.value['name'] or 'CORPORA · ' + main.get('name', 'My workspace'),
                    device=self.value['device'], scope=self.value['scope'], status=self.value['status'],
                    revision=self.value['revision'], chief_id=service.registry.main, settings_template=prompt('corpora-settings-request').strip(),
                    stopping=bool(service.execution.runners or service.agencies.slots) and not service.pulse.running)

    def update(self, data):
        if not data or set(data) - {'name', 'device', 'scope', 'revision', 'archived'}:
            raise APIError(400, 'Unknown corpora setting')
        with self.service._lock:
            if data.get('revision') != self.value['revision']:
                raise APIError(409, 'Corpora changed. Read its settings again.')
            for key, limit in [('name', 200), ('device', 200), ('scope', 16000)]:
                if key in data and (not isinstance(data[key], str) or len(data[key].strip()) > limit or
                                   (key != 'scope' and not data[key].strip())):
                    raise APIError(400, 'Invalid ' + key)
            if 'archived' in data:
                if type(data['archived']) is not bool:
                    raise APIError(400, 'archived must be a boolean')
                if data['archived']:
                    self.service.execution.stop_pulse()
                self.value['status'] = 'archived' if data['archived'] else 'paused'
            self.value.update({k: data[k].strip() for k in ('name', 'device', 'scope') if k in data})
            self.value['revision'] += 1
            self.save()
            for row in self.service.store.agents():
                self.service.population.manifests(self.service.population.agent(row['id']), row)
            return self.identity()

    def lifecycle(self, data):
        operation, action = data.get('operation'), data.get('action')
        if set(data) - {'operation', 'action', 'revision'} or action not in {'pause', 'activate'} or not isinstance(operation, str) or not 8 <= len(operation) <= 80:
            raise APIError(400, 'Provide an operation ID and pause or activate')
        service = self.service
        with service._lock:
            previous = self.value['operations'].get(operation)
            if previous:
                if previous != [action, data.get('revision')]:
                    raise APIError(409, 'Operation ID was reused')
                return self.identity()
            if data.get('revision') != self.value['revision']:
                raise APIError(409, 'Corpora changed. Refresh before trying again.')
            if self.value['status'] == 'archived':
                raise APIError(409, 'Restore this archived corpora before activating it')
            if action == 'activate' and (service.execution.runners or service.agencies.slots) and not service.pulse.running:
                raise APIError(409, 'Work is still stopping. Try again shortly.')
            self.value['status'] = 'paused' if action == 'pause' else 'active'
            self.value['revision'] += 1
            self.value['operations'][operation] = [action, data.get('revision')]
            self.value['operations'] = dict(list(self.value['operations'].items())[-256:])
            self.save()  # Persist intent before scheduling or interrupting work.
            if action == 'pause':
                service.execution.stop_pulse()
            else:
                service.start()
            runners = list(service.execution.runners.values()) + [entry[1] for entry in service.agencies.slots.values()]
        deadline = time.monotonic() + 5
        if action == 'pause':
            for runner in runners:
                runner.join(max(0, deadline - time.monotonic()))
        with service._lock:
            return self.identity()
