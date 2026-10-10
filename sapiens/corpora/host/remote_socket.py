"""Synchronous desktop transport; the relay never receives device private keys."""
from collections import deque
import json
import time

try:
    import websocket
except ImportError:
    websocket = None

from sapiens.corpora.host.remote_pairing import MAX_FRAME


class SocketClient:
    def __init__(self, config):
        if websocket is None:
            raise ValueError('Install remote-requirements.txt for WebSocket support')
        relay = config['relay']
        url = ('wss' if relay.startswith('https:') else 'ws') + relay[relay.index(':'):] + '/api/socket'
        self.socket = websocket.create_connection(url, timeout=5, origin=relay, redirect_limit=0)
        self.messages, self.serial = deque(), 0
        try:
            self.socket.send(json.dumps(dict(type='auth', room=config['room'], token=config['token'])))
            if self.read().get('type') != 'ready':
                raise ValueError('Mailbox authentication failed')
        except Exception:
            self.close()
            raise

    def close(self):
        try:
            self.socket.close(timeout=1)
        finally:
            self.socket.shutdown()

    def read(self, timeout=5):
        self.socket.settimeout(timeout)
        raw = self.socket.recv()
        if not isinstance(raw, str) or len(raw) > MAX_FRAME + 8192:
            raise ValueError('Invalid relay socket message')
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ValueError('Invalid relay socket response')
        return value

    def collect(self, value):
        messages = value.get('messages')
        if value.get('type') != 'messages' or not isinstance(messages, list) or len(messages) > 20:
            raise ValueError('Invalid relay delivery')
        if len(self.messages) + len(messages) > 40:
            raise ValueError('Relay delivery overflow')
        self.messages.extend(messages)

    def call(self, kind, **body):
        self.serial += 1
        id_ = str(self.serial)
        self.socket.send(json.dumps(dict(type=kind, id=id_, **body)))
        deadline = time.monotonic() + 10
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError('Relay did not confirm delivery')
            value = self.read(max(.01, deadline - time.monotonic()))
            if value.get('type') == 'messages':
                self.collect(value)
                continue
            if value.get('type') != 'result' or value.get('id') != id_:
                raise ValueError('Unexpected relay response')
            if value.get('error'):
                raise ValueError(value['error'])
            return value.get('result')

    def receive(self):
        if not self.messages:
            try:
                self.collect(self.read(.5))
            except websocket.WebSocketTimeoutException:
                return None  # Local wakeup for approval/shutdown; no network request.
        return self.messages.popleft() if self.messages else None
