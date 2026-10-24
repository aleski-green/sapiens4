"""A device's local corpora and trusted remote connections. Never relay-exposed."""
import json
import sys
import threading
from uuid import uuid4

from sapiens.corpora.host.corpora_api import dispatch
from sapiens.corpora.host.remote_client import RemoteClient
from sapiens.corpora.host.remote_bridge import RemoteBridge
from sapiens.corpora.host.remote_pairing import confirmation_code
from sapiens.files import atomic_json
from sapiens.validation import APIError
from sapiens.corpora.host.relay_servers import RelayServers, reset_saved_connections


class HostRegistry:
    def __init__(self, server):
        self.server = server
        self.root = server.service.root
        self.path = self.root / 'host-corpora.json'
        self.saved = json.loads(self.path.read_text()) if self.path.exists() else {'locals': [], 'remotes': {}}
        self.local_available = sys.platform in {'darwin', 'win32'}
        self.services = {server.service.corpora_id: server.service}
        self.children, self.clients, self.pending = {}, {}, {}
        self.pair_clients = {}
        self.lock = threading.RLock()
        self.closed = False
        self.relays = RelayServers(self)
        if self.saved.get('relay_cleanup'):
            threading.Thread(target=self.cleanup_relays, daemon=True).start()

    def save(self):
        atomic_json(self.path, self.saved)

    def local(self, identity):
        if identity in self.services:
            return self.services[identity]
        if identity not in self.saved['locals']:
            raise APIError(404, 'Unknown corpora')
        from sapiens.corpora.host.service import Service
        from sapiens.corpora.host.server import Server
        folder = self.root / 'corporas' / identity
        if not (folder / 'corpora-identity.json').exists():
            raise APIError(409, 'Corpora files are unavailable. Restore them before opening.')
        service = Service(folder, start_worker=False)
        server = Server(0, service, managed=True)
        if not server.remote.saved_relay() and self.server.remote.saved_relay():
            atomic_json(server.remote.relay_path, self.server.remote.saved_relay())
        self.services[identity], self.children[identity] = service, server
        threading.Thread(target=server.serve_forever, daemon=True).start()
        service.start()
        return service

    def records(self):
        with self.lock:
            local = []
            if self.local_available:
                for identity in [self.server.service.corpora_id, *self.saved['locals']]:
                    info = self.local(identity).corpora_identity()
                    bridge = self.server.remote if identity == self.server.service.corpora_id else self.children[identity].remote
                    local.append(dict(info, location='Local', paired=bridge.status()['paired']))
            remote = [dict(item['corpora'], location='Remote') for item in self.saved['remotes'].values()]
            return dict(local_available=self.local_available, corpora=local + remote)

    def route(self, identity, method, path, data):
        with self.lock:
            if identity in self.saved['remotes']:
                if identity not in self.clients:
                    self.clients[identity] = RemoteClient(self.saved['remotes'][identity])
                client = self.clients[identity]
                service = None
            else:
                service = self.local(identity) if self.local_available else None
                if service is None:
                    raise APIError(404, 'Local corpora are unavailable on this device')
        # Credentials and other host corpora never cross a remote connection.
        if not path.startswith('/api/') or path.startswith('/api/host') or '%' in path.split('?')[0] or '..' in path or '\\' in path:
            raise APIError(400, 'Invalid corpora API path')
        if path.startswith('/api/remote'):
            if service is None:
                raise APIError(403, 'Pairing approval is available on the host only')
            remote = self.server.remote if service is self.server.service else self.children[identity].remote
            if path == '/api/remote' and method == 'GET':
                return 200, remote.status(), 'application/json'
            if method == 'POST':
                return 200, self.remote_action(remote, path, data), 'application/json'
            raise APIError(404, 'Not found')
        result = dispatch(service, method, path, data) if service else client.request(method, path, data)
        if service is None:
            with self.lock:
                if identity not in self.saved['remotes'] or self.clients.get(identity) is not client:
                    raise APIError(410, 'Remote connection was revoked')
        if service is None and result[0] == 200:
            metadata = result[1].get('corpora') if path == '/api/state' else result[1] if path in {'/api/corpora', '/api/corpora/lifecycle'} else None
            if metadata and metadata.get('id') == identity:
                with self.lock:
                    if identity not in self.saved['remotes']:
                        raise APIError(410, 'Remote connection was revoked')
                    if self.saved['remotes'][identity]['corpora'] != metadata:
                        self.saved['remotes'][identity]['corpora'] = metadata
                        self.save()
        return result

    def remote_action(self, remote, path, data):
        with self.lock:
            if self.saved.get('relay_servers', {}).get('reset_pending'):
                raise APIError(409, 'Relay switch interrupted. Restart the app to finish.')
            if path == '/api/remote/pair':
                if 'relay_servers' in self.saved:
                    connection = self.relays.connection()
                    if not data.get('saved') or data.get('local'):
                        raise APIError(409, 'Choose the relay in Remote Control Relay Servers.')
                    self.cleanup_relays(connection['relay'], remote.service.corpora_id)
                    return remote.create(connection)
                return remote.create(data)
            if path == '/api/remote/approve':
                return remote.approve(data)
            if path == '/api/remote/revoke':
                return remote.revoke()
            raise APIError(404, 'Not found')

    def queue_relay_cleanup(self):
        pending = self.saved.setdefault('relay_cleanup', [])
        folders = [(self.root, self.server.service.corpora_id),
                   *((self.root / 'corporas' / identity, identity) for identity in self.saved['locals'])]
        for folder, identity in folders:
            try:
                config = json.loads((folder / 'remote-device.json').read_text())
                item = {key: config[key] for key in ('relay', 'room', 'token')}
                item['corpora_id'] = config.get('corpora_id', identity)
                if item not in pending:
                    pending.append(item)
            except (OSError, ValueError, TypeError, KeyError):
                continue

    def cleanup_relays(self, relay=None, identity=None):
        with self.lock:
            pending = [item for item in self.saved.get('relay_cleanup', [])
                       if (relay is None or item['relay'] == relay) and
                          (identity is None or item['corpora_id'] == identity)]
        for item in pending:
            if self.closed:
                return
            if RemoteBridge.delete_room(item):
                with self.lock:
                    if item in self.saved.get('relay_cleanup', []):
                        self.saved['relay_cleanup'].remove(item)
                        self.save()

    def reset_connections(self, connection):
        for item in self.pending.values():
            item['state'] = 'cancelled'
        for client in [*self.clients.values(), *self.pair_clients.values()]:
            client.revoke()
        self.clients.clear()
        for server in [self.server, *self.children.values()]:
            server.remote.revoke(notify=False)
        reset_saved_connections(self.root, self.saved['locals'], connection)
        threading.Thread(target=self.cleanup_relays, daemon=True).start()

    def create(self, data):
        if not self.local_available:
            raise APIError(403, 'Local corpora are unavailable on this device')
        if set(data) - {'name', 'scope'} or not isinstance(data.get('name'), str) or not data['name'].strip() or len(data['name']) > 200 or not isinstance(data.get('scope', ''), str) or len(data.get('scope', '')) > 16000:
            raise APIError(400, 'Provide a corpora name and scope of work')
        from sapiens.corpora.host.service import Service
        identity = str(uuid4())
        folder = self.root / 'corporas' / identity
        folder.mkdir(parents=True, mode=0o700)
        atomic_json(folder / 'corpora-identity.json', {'version': 1, 'corpora_id': identity})
        atomic_json(folder / 'corpora-settings.json', dict(name=data['name'].strip(), scope=data.get('scope', '').strip(),
                    device=self.server.service.corpora_identity()['device'], status='paused', revision=1, operations={}))
        with self.lock:
            self.saved['locals'].append(identity)
            self.save()
            service = self.local(identity)
            service.update_agent(service.registry.main, {'name': 'ChiefSapi', 'role': 'Head of Corpora'})
            return dict(service.corpora_identity(), location='Local')

    def begin_pair(self, data):
        client = RemoteClient.invitation(data)
        identity = uuid4().hex
        item = dict(id=identity, state='waiting', code=confirmation_code(data['desktop'], client.config['public'], data['room']))
        with self.lock:
            if self.saved.get('relay_servers', {}).get('reset_pending'):
                raise APIError(409, 'Relay switch interrupted. Restart the app to finish.')
            if any(p['state'] == 'waiting' for p in self.pending.values()):
                raise APIError(409, 'A connection is already waiting for approval')
            self.pending = {identity: item}
            self.pair_clients[identity] = client
        def pair():
            try:
                corpora = client.pair(data)
                with self.lock:
                    if self.closed or item['state'] == 'cancelled':
                        return
                    if corpora['id'] in self.services or corpora['id'] in self.saved['locals']:
                        raise APIError(409, 'This corpora is already available locally')
                    self.saved['remotes'][corpora['id']] = client.config
                    self.save()
                    item.update(state='approved', corpora=dict(corpora, location='Remote'))
            except Exception as error:
                with self.lock:
                    if item['state'] != 'cancelled':
                        item.update(state='failed', error=str(error))
            finally:
                client.close()
                with self.lock:
                    self.pair_clients.pop(identity, None)
        threading.Thread(target=pair, daemon=True).start()
        return item.copy()

    def pairing(self, identity, cancel=False):
        with self.lock:
            if identity not in self.pending:
                raise APIError(404, 'Unknown pairing')
            if cancel:
                self.pending[identity]['state'] = 'cancelled'
                if identity in self.pair_clients:
                    self.pair_clients[identity].revoke()
            return self.pending[identity].copy()

    def close(self):
        self.closed = True
        for client in [*self.clients.values(), *self.pair_clients.values()]:
            client.revoke()
        for identity, server in self.children.items():
            server.shutdown()
            server.server_close()
            self.services[identity].close()
