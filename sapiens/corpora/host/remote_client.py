"""Native client of the existing encrypted relay protocol (one serialized socket)."""
import json
import re
import threading
import time
from uuid import UUID, uuid4

from sapiens.corpora.host import remote_pairing as crypto
from sapiens.corpora.host.remote_socket import SocketClient
from sapiens.validation import APIError


class RemoteClient:
    def __init__(self, config):
        self.config, self.socket = config, None
        self.lock = threading.Lock()

    def close(self):
        if self.socket:
            try:
                self.socket.close()
            except Exception:
                pass
            self.socket = None

    def exchange(self, payload, timeout=12):
        with self.lock:
            identity = uuid4().hex
            data = dict(id=identity, expires=time.time() + timeout,
                        corpora_id=self.config.get('corpora', {}).get('id'), **payload)
            frame = crypto.pack(self.config['private'], self.config['desktop'], self.config['room'], 'phone-to-desktop', data)
            try:
                if self.socket is None:
                    self.socket = SocketClient(self.config)
                self.socket.call('send', frame=frame)
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    item = self.socket.receive()
                    if not item:
                        continue
                    try:
                        response = crypto.unpack(self.config['private'], self.config['desktop'], self.config['room'], 'desktop-to-phone', item['frame'])
                    except (ValueError, KeyError):
                        self.socket.call('ack', message=item['id'])
                        continue
                    self.socket.call('ack', message=item['id'])
                    if response.get('id') != identity or response.get('kind') != 'response':
                        continue
                    result = response['result']
                    if result.get('error'):
                        raise APIError(409, result['error'])
                    return result
                raise TimeoutError('Host did not respond')
            except APIError:
                raise
            except Exception as error:
                self.close()
                raise APIError(503, 'This device is unreachable. Try again later.') from error

    def request(self, method, path, data=None):
        result = self.exchange(dict(kind='request', op='api', method=method, path=path, data=data))
        return result['status'], crypto.unb64(result['body']) if result.get('binary') else result['body'], result['mime']

    @classmethod
    def invitation(cls, value):
        if not isinstance(value, dict) or value.get('v') != crypto.PROTOCOL:
            raise APIError(400, 'Invalid pairing invitation')
        relay = crypto.origin(value.get('relay'))
        for field in ('room', 'token', 'secret'):
            if not isinstance(value.get(field), str) or not re.fullmatch(r'[A-Za-z0-9_-]{32,64}', value[field]):
                raise APIError(400, 'Invalid pairing invitation')
        if type(value.get('expires')) not in (int, float) or not time.time() < value['expires'] <= time.time() + crypto.PAIRING_TTL + 60:
            raise APIError(400, 'Invitation expired. Show a new QR on the host.')
        crypto.unb64(value.get('desktop'), 32)
        private, public = crypto.keypair()
        return cls(dict(relay=relay, room=value['room'], token=value['token'], desktop=value['desktop'], private=private, public=public))

    def pair(self, invitation):
        result = self.exchange(dict(kind='pair', secret=invitation['secret']), timeout=min(180, invitation['expires'] - time.time()))
        corpora = result.get('corpora')
        if not result.get('paired') or not isinstance(corpora, dict) or str(UUID(corpora['id'])) != corpora['id']:
            raise APIError(409, 'Corpora identity could not be verified')
        self.config['corpora'] = corpora
        return corpora
