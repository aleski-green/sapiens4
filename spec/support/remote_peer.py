"""Independent NaCl/WebSocket peer. No application modules or browser internals."""
import base64
import json
import sys
import threading
import time
from nacl.public import Box, PrivateKey, PublicKey
from nacl.utils import random
import websocket


def b64(value):
    return base64.b64encode(bytes(value)).decode()


def raw(value):
    return base64.b64decode(value)


class Connection:
    def __init__(self, data):
        self.messages, self.closed, self.error = [], None, None
        self.changed = threading.Condition()
        self.ws = websocket.create_connection(
            data['url'].replace('http', 'ws', 1) + '/api/socket',
            origin=data.get('origin', data['url']), timeout=5)
        self.ws.settimeout(None)
        self.ws.send(json.dumps({'type': 'auth', 'room': data['room'], 'token': data['token']}))
        self.thread = threading.Thread(target=self.receive, daemon=True)
        self.thread.start()

    def receive(self):
        try:
            while True:
                opcode, payload = self.ws.recv_data(control_frame=True)
                with self.changed:
                    if opcode == websocket.ABNF.OPCODE_CLOSE:
                        self.closed = int.from_bytes(payload[:2], 'big') if len(payload) >= 2 else 1005
                        self.changed.notify_all()
                        return
                    if opcode == websocket.ABNF.OPCODE_TEXT:
                        self.messages.append(json.loads(payload))
                        self.changed.notify_all()
        except Exception as error:
            with self.changed:
                self.closed = self.closed or 1006
                self.error = str(error)
                self.changed.notify_all()

    def read(self, timeout=5, request=None):
        deadline = time.monotonic() + timeout
        with self.changed:
            while True:
                for index, message in enumerate(self.messages):
                    if request is None or (message.get('type') == 'result' and message.get('id') == request):
                        return self.messages.pop(index)
                if self.closed:
                    return {'closed': self.closed, 'error': self.error}
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self.changed.wait(remaining)

    def close(self):
        self.ws.close()
        self.thread.join(5)
        if self.thread.is_alive():
            raise RuntimeError('WebSocket fixture did not stop')


peers, serial = {}, 0


def run(data):
    global serial
    op = data['op']
    if op == 'keys':
        key = PrivateKey.generate()
        return {'private': b64(key), 'public': b64(key.public_key)}
    if op in ('pack', 'unpack'):
        key = PrivateKey(raw(data['private']))
        box = Box(key, PublicKey(raw(data['public'])))
        if op == 'unpack':
            frame = data['frame']
            return json.loads(box.decrypt(raw(frame['ciphertext']), raw(frame['nonce'])))
        nonce = random(Box.NONCE_SIZE)
        body = {'v': 'sapiens-remote-box-v1', 'room': data['room'],
            'direction': 'phone-to-desktop', **data['body']}
        return {'sender': b64(key.public_key), 'nonce': b64(nonce),
            'ciphertext': b64(box.encrypt(json.dumps(body).encode(), nonce).ciphertext)}
    if op == 'connect':
        if data['name'] in peers:
            peers[data['name']].close()
        peers[data['name']] = Connection(data)
        return peers[data['name']].read()
    peer = peers[data['name']]
    if op == 'status':
        return {'closed': peer.closed, 'error': peer.error}
    if op == 'close':
        peer.close()
        return True
    if op == 'read':
        return peer.read(data.get('timeout', 5000) / 1000)
    if op == 'call':
        serial += 1
        request = str(serial)
        peer.ws.send(json.dumps({'id': request, **data['body']}))
        return peer.read(request=request)
    raise ValueError('Unknown operation: ' + op)


try:
    for line in sys.stdin:
        try:
            print(json.dumps({'value': run(json.loads(line))}), flush=True)
        except Exception as error:
            print(json.dumps({'error': str(error)}), flush=True)
finally:
    for peer in peers.values():
        peer.close()
