"""Private app-wide relay catalogue and crash-safe trust reset."""
import copy
import json
from uuid import uuid4

from sapiens.files import atomic_json
from sapiens.corpora.host.remote_setup import FORMAT, read, validate
from sapiens.validation import APIError

BUILTINS = (
    ('sapiens-beta', 'Sapiens4 beta', 'https://remote-relay.sapiens4.ai', True),
    ('utana-beta', 'Utana beta', 'https://remote-relay.utana.group', False),
)


def recover(root):
    """Finish a committed reset before any bridge starts accepting traffic."""
    path = root / 'host-corpora.json'
    if not path.exists():
        return
    saved = json.loads(path.read_text())
    state = saved.get('relay_servers', {})
    if not state.get('reset_pending'):
        return
    selected = next(row for row in state['servers'] if row['id'] == state['selected'])
    for folder in [root, *(root / 'corporas' / identity for identity in saved['locals'])]:
        (folder / 'remote-device.json').unlink(missing_ok=True)
        if folder.exists():
            atomic_json(folder / 'remote-relay.json', selected['connection'])
    saved['remotes'] = {}
    state.pop('reset_pending')
    atomic_json(path, saved)


class RelayServers:
    def __init__(self, registry):
        self.registry = registry

    def state(self):
        saved = self.registry.saved
        if 'relay_servers' not in saved:
            rows = [dict(id=id_, name=name, address=relay + '/beta', available=available,
                         archived=False, builtin=True,
                         connection=dict(format=FORMAT, relay=relay, beta=True))
                    for id_, name, relay, available in BUILTINS]
            selected = rows[0]['id']
            # Import every distinct old configuration without touching existing trust.
            folders = [self.registry.root, *(self.registry.root / 'corporas' / identity for identity in saved['locals'])]
            for folder in folders:
                try:
                    connection = read(folder / 'remote-relay.json')
                except (OSError, ValueError, TypeError):
                    continue
                match = next((r for r in rows if r['connection'] == connection), None)
                if not match:
                    match = dict(id=uuid4().hex, name='My relay' if folder == self.registry.root else 'Imported relay',
                                 connection=connection, available=True, archived=False, builtin=False)
                    rows.append(match)
                if folder == self.registry.root:
                    selected = match['id']
            saved['relay_servers'] = dict(servers=rows, selected=selected, revision=1, beta_accepted=False)
            self.registry.save()
        return saved['relay_servers']

    def view(self, id_=None):
        with self.registry.lock:
            state = self.state()
            if id_ is not None:
                return copy.deepcopy(self.find(id_))
            # Tokens only leave the host in an explicitly requested editor response.
            return dict(selected=state['selected'], revision=state['revision'],
                        beta_accepted=state['beta_accepted'], servers=[
                {**{k: v for k, v in row.items() if k != 'connection'},
                 'address': row.get('address') or row['connection']['relay'],
                 'beta': row['connection'].get('beta', False)} for row in state['servers']])

    def find(self, id_):
        row = next((row for row in self.state()['servers'] if row['id'] == id_), None)
        if row is None:
            raise APIError(404, 'Unknown relay server')
        return row

    def change(self, data):
        with self.registry.lock:
            state = self.state()
            if data.get('revision') != state['revision']:
                raise APIError(409, 'Relay settings changed. Reopen the selector.')
            action, id_ = data.get('action'), data.get('id')
            row = self.find(id_) if id_ else None
            reset = False
            if action == 'save':
                name = data.get('name')
                if not isinstance(name, str) or not name.strip() or len(name) > 200:
                    raise APIError(400, 'Enter a name (up to 200 characters).')
                connection = validate(data.get('connection'))
                reset = bool(row and id_ == state['selected'] and connection != row['connection'])
                updated = dict(row or dict(id=uuid4().hex, archived=False, available=True, builtin=False),
                               name=name.strip(), connection=connection)
            elif action == 'switch':
                if not row or row['archived'] or not row['available']:
                    raise APIError(409, 'This relay is unavailable.')
                reset = id_ != state['selected']
            elif action in {'archive', 'restore'}:
                if not row:
                    raise APIError(404, 'Unknown relay server')
                if action == 'archive' and id_ == state['selected']:
                    raise APIError(409, 'Switch servers before archiving this relay.')
            elif action != 'accept-beta':
                raise APIError(400, 'Unknown relay action')
            if reset and data.get('confirm_revoke') is not True:
                raise APIError(409, 'Confirm revoking all paired devices and remote corpora connections.')
            if action == 'save':
                if row:
                    if connection != row['connection']:
                        updated.pop('address', None)
                        row.pop('address', None)
                        if id_ == state['selected']:
                            state['beta_accepted'] = False
                    row.update(updated)
                else:
                    state['servers'].append(updated)
            elif action == 'switch':
                state['selected'] = id_
                if reset:
                    state['beta_accepted'] = False
            elif action in {'archive', 'restore'}:
                row['archived'] = action == 'archive'
            elif action == 'accept-beta':
                if data.get('accepted') is not True:
                    raise APIError(400, 'Accept the beta terms to continue.')
                state['beta_accepted'] = True
            state['revision'] += 1
            if reset:
                self.registry.queue_relay_cleanup()
                state['reset_pending'] = True
                self.registry.saved['remotes'] = {}
                # Commit the decision first. Startup recovery finishes any interrupted reset.
                self.registry.save()
                self.registry.reset_connections(self.find(state['selected'])['connection'])
                state.pop('reset_pending')
            self.registry.save()
            return dict(self.view(), reset=reset)

    def connection(self):
        state = self.state()
        row = self.find(state['selected'])
        if row['archived'] or not row['available']:
            raise APIError(409, 'Select an available relay.')
        if row['connection'].get('beta') and not state['beta_accepted']:
            raise APIError(409, 'Accept the beta terms before pairing.')
        return row['connection']
