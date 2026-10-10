"""Opt-in local authority: QR pairing, device approval, and the shared CORPORA API."""
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import threading
import time
from urllib.parse import urlsplit
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from sapiens.corpora.host.corpora_api import dispatch
from sapiens.files import atomic_json
from sapiens.corpora.host import remote_pairing as crypto
from sapiens.corpora.host.remote_setup import local_connection
from sapiens.corpora.host.remote_socket import SocketClient, websocket
from sapiens.validation import APIError


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # Never forward mailbox or provisioning credentials to a redirect.


def request(relay, path, bearer, method='GET', body=None):
    raw = json.dumps(body).encode() if body is not None else None
    req = Request(relay + path, data=raw, method=method,
                  headers={'Authorization': 'Bearer ' + bearer, 'Content-Type': 'application/json'})
    try:
        with build_opener(NoRedirect).open(req, timeout=5) as response:
            raw = response.read(24_000_001)
            if len(raw) > 24_000_000:
                raise ValueError('Relay response too large')
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise ValueError('Invalid relay response')
            return value
    except HTTPError as error:
        raise ValueError('Relay request failed (HTTP %s)' % error.code) from None


class RemoteBridge:
    def __init__(self, service):
        self.service = service
        self.path = service.root / 'remote-device.json'
        self.receipts = service.root / 'remote-receipts.sqlite3'
        self.lock, self.stopped = threading.RLock(), threading.Event()
        self.config = None
        self.error, self.last_contact = '', None
        if self.path.exists():
            try:
                config = json.loads(self.path.read_text())
                crypto.origin(config['relay'])
                crypto.unb64(config['private'], 32)
                crypto.unb64(config['public'], 32)
                if config.get('peer'):
                    crypto.unb64(config['peer'], 32)
                if (not isinstance(config['room'], str) or not isinstance(config['token'], str) or
                        type(config['expires']) not in (int, float)):
                    raise ValueError('Invalid saved pairing')
                self.config = config
            except (OSError, ValueError, TypeError, KeyError):
                self.error = 'Saved remote pairing is invalid. Create a new pairing; local CORPORA is unaffected.'
        self.thread = None
        if self.config and crypto.available():
            self.start()

    def start(self):
        if self.thread is None:
            self.thread = threading.Thread(target=self.run, name='corpora-remote', daemon=True)
            self.thread.start()

    def save(self):
        if self.config is None:
            self.path.unlink(missing_ok=True)
        else:
            atomic_json(self.path, self.config)  # Atomic helper creates mode 0600 files.

    def status(self):
        with self.lock:
            config = self.config or {}
            pending = config.get('pending')
            return dict(available=crypto.available() and websocket is not None, enabled=bool(config),
                        local_relay=bool(local_connection()),
                        paired=bool(config.get('peer')), relay=config.get('relay'),
                        fingerprint=crypto.fingerprint(config['peer']) if config.get('peer') else None,
                        pending=dict(fingerprint=crypto.fingerprint(pending['peer']), peer=pending['peer'])
                        if pending and config['expires'] > time.time() else None,
                        expires=config.get('expires'), error=self.error, last_contact=self.last_contact)

    def create(self, data):
        if websocket is None:
            raise ValueError('Install remote-requirements.txt to enable WebSocket remote access')
        if data.get('local') is True:
            data = local_connection()
            if not data:
                raise ValueError('Local test relay setup is missing. Start the relay or import its connection file.')
        relay = crypto.origin(data.get('relay'))
        admin = data.get('token', '')
        if not isinstance(admin, str) or not 32 <= len(admin) <= 256 or not admin.isascii():
            raise ValueError('Enter the relay provisioning token (32–256 ASCII characters)')
        private, public = crypto.keypair()
        with self.lock:
            if self.config:
                raise ValueError('Revoke the existing pairing before creating another')
            room = request(relay, '/api/rooms', admin, 'POST', {})
            if any(not isinstance(room.get(k), str) or not 32 <= len(room[k]) <= 64 or
                   any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in room[k])
                   for k in ('room', 'desktop', 'phone')):
                raise ValueError('Invalid relay mailbox')
            self.error = ''
            secret = crypto.token()
            expires = time.time() + 120
            self.config = dict(relay=relay, room=room['room'], token=room['desktop'],
                               private=private, public=public, secret=secret, expires=expires,
                               peer=None, pending=None)
            self.save()
            self.start()
            # The provisioning token and desktop private key are never placed in the QR.
            return dict(qr=dict(v=crypto.PROTOCOL, relay=relay, room=room['room'], token=room['phone'],
                                desktop=public, secret=secret, expires=expires))

    def approve(self, data):
        with self.lock:
            config = self.config
            pending = config.get('pending') if config else None
            if not pending or config['expires'] <= time.time() or data.get('peer') != pending['peer']:
                raise ValueError('Pairing expired or phone changed; generate a new QR')
            config['peer'] = pending['peer']
            config['accept'] = self.response(pending['id'], dict(paired=True))
            config['pending'] = None
            config.pop('secret', None)
            self.save()
            return dict(approved=True)

    def revoke(self):
        with self.lock:
            config, self.config = self.config, None
            self.save()  # Local revocation takes effect even if relay is unreachable.
            self.error, self.last_contact = '', None
        deleted = True
        if config:
            try:
                request(config['relay'], '/api/rooms/' + config['room'], config['token'], 'DELETE')
            except Exception:
                deleted = False
        return dict(revoked=True, relay_deleted=deleted)

    def close(self):
        self.stopped.set()
        if self.thread:
            self.thread.join()

    def connect(self):
        if not self.receipts.exists():
            fd = os.open(self.receipts, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
        db = sqlite3.connect(self.receipts)
        db.execute('CREATE TABLE IF NOT EXISTS receipts (room TEXT, id TEXT, hash TEXT, reply TEXT, '
                   'created REAL, PRIMARY KEY(room,id))')
        return db

    def response(self, id_, value):
        config = self.config
        return crypto.pack(config['private'], config['peer'], config['room'], 'desktop-to-phone',
                           dict(id=id_, expires=time.time() + 86400 - 10, kind='response', result=value))

    def process(self, frame):
        config = self.config
        peer = config.get('peer') or frame.get('sender')
        message = crypto.unpack(config['private'], peer, config['room'], 'phone-to-desktop', frame)
        if not config.get('peer'):
            if (message.get('kind') != 'pair' or config['expires'] <= time.time() or
                    not isinstance(message.get('secret'), str) or
                    not hmac.compare_digest(message['secret'], config['secret'])):
                raise ValueError('Invalid pairing proof')
            if config.get('pending') and config['pending']['peer'] != peer:
                raise ValueError('Another phone is awaiting approval')
            config['pending'] = dict(peer=peer, id=message['id'])
            self.save()
            return None
        if message.get('kind') != 'request' or message['expires'] > time.time() + 310:
            raise ValueError('Invalid request')
        if message.get('op') == 'api' and message.get('method') == 'GET':
            # Reads are safe to repeat; do not retain a full desktop snapshot per poll.
            try:
                return self.response(message['id'], self.execute(message))
            except (ValueError, APIError) as error:
                return self.response(message['id'], dict(error=str(error)))
            except Exception:
                return self.response(message['id'], dict(error='Local operation failed; check desktop'))
        hash_ = hashlib.sha256(json.dumps(message, sort_keys=True).encode()).hexdigest()
        with self.connect() as db:
            db.execute('DELETE FROM receipts WHERE created < ?', (time.time() - 86400,))
            row = db.execute('SELECT hash, reply FROM receipts WHERE room=? AND id=?',
                             (config['room'], message['id'])).fetchone()
            if row:
                if row[0] != hash_:
                    raise ValueError('Request ID was reused')
                return json.loads(row[1]) if row[1] else self.response(message['id'],
                    dict(error='Outcome uncertain after interruption. Check desktop history before sending again.'))
            db.execute('INSERT INTO receipts VALUES (?, ?, ?, NULL, ?)',
                       (config['room'], message['id'], hash_, time.time()))
        # Durable intent before side effects. Never repeat an interrupted command automatically.
        try:
            value = self.execute(message)
        except (ValueError, APIError) as error:
            value = dict(error=str(error))
        except Exception:
            value = dict(error='Local operation failed; check desktop before sending again')
        try:
            reply = self.response(message['id'], value)
        except ValueError:
            reply = self.response(message['id'], dict(error='Response too large; inspect on desktop'))
        with self.connect() as db:
            db.execute('UPDATE receipts SET reply=? WHERE room=? AND id=?',
                       (json.dumps(reply), config['room'], message['id']))
        return reply

    def execute(self, message):
        op = message.get('op')
        if op == 'api':
            method, target = message.get('method'), message.get('path')
            if method not in {'GET', 'POST', 'PUT'} or not isinstance(target, str) or len(target) > 8192:
                raise ValueError('Unsupported remote API request')
            url = urlsplit(target)
            parts = url.path.strip('/').split('/')
            if (url.scheme or url.netloc or url.fragment or not target.startswith('/api/') or
                    '%' in url.path or '..' in parts or '\\' in target or
                    parts[:2] == ['api', 'remote'] or
                    (method != 'GET' and len(parts) == 4 and parts[3] == 'browser')):
                raise ValueError('Remote API route is not allowed')
            try:
                status, value, mime = dispatch(self.service, method, target, message.get('data'))
            except APIError as error:
                status, value, mime = error.status, dict(error=str(error)), 'application/json'
            except ValueError as error:
                status, value, mime = 409, dict(error=str(error)), 'application/json'
            binary = isinstance(value, bytes)
            return dict(status=status, body=crypto.b64(value) if binary else value, mime=mime, binary=binary)
        if op == 'state':
            snapshot = self.service.snapshot()
            agents = [dict(id=a['id'], name=a.get('name', a['id']), role=a.get('role', ''))
                      for a in snapshot['agents'] if not a.get('retired')]
            selected = message.get('agent') or next((a['id'] for a in agents), '')
            if selected and selected not in {a['id'] for a in agents}:
                raise ValueError('Unknown Sapi')
            turns = [dict(id=t['id'], input=str(t.get('input', ''))[:16000],
                          output=str(t.get('output') or '')[-16000:], status=t.get('status', ''))
                     for t in snapshot['turns'] if t.get('agent') == selected][-8:]
            return dict(agents=agents, agent=selected, turns=turns, updated=time.time())
        if op == 'chat':
            text, agent = message.get('text'), message.get('agent')
            if not isinstance(text, str) or not text.strip() or len(text) > 16000 or not isinstance(agent, str):
                raise ValueError('Select a Sapi and enter a message (up to 16000 characters)')
            return dict(submitted=self.service.submit(agent, {'text': text, 'flow': 'chat'}))
        raise ValueError('Remote operation not allowed')

    def step(self):
        with self.lock:
            config = self.config
            if not config:
                return
            path = '/api/rooms/' + config['room'] + '/messages'
            if config.get('accept'):
                request(config['relay'], path, config['token'], 'POST', config['accept'])
                config.pop('accept')
                self.save()
            result = request(config['relay'], path, config['token'])
            messages = result.get('messages')
            if not isinstance(messages, list) or len(messages) > 20:
                raise ValueError('Invalid relay response')
            for item in messages:
                if self.stopped.is_set():
                    return
                if not isinstance(item, dict) or type(item.get('id')) is not int or item['id'] <= 0:
                    raise ValueError('Invalid relay message')
                try:
                    reply = self.process(item.get('frame', {}))
                except Exception:
                    # Invalid ciphertext is untrusted input, never an application command.
                    reply = None
                if reply:
                    request(config['relay'], path, config['token'], 'POST', reply)
                request(config['relay'], path + '/' + str(item['id']), config['token'], 'DELETE')
            self.last_contact, self.error = time.time(), ''

    def run(self):
        delay = 1
        while not self.stopped.is_set():
            with self.lock:
                config = self.config
            if not config:
                self.stopped.wait(.5)
                continue
            client = None
            try:
                client = SocketClient(config)
                delay = 1
                with self.lock:
                    self.error, self.last_contact = '', time.time()
                while not self.stopped.is_set():
                    with self.lock:
                        if self.config is not config:
                            break
                        if config.get('accept'):
                            client.call('send', frame=config['accept'])
                            config.pop('accept')
                            self.save()
                    item = client.receive()
                    if item is None:
                        continue
                    with self.lock:
                        if self.config is not config:
                            break
                        if not isinstance(item, dict) or type(item.get('id')) is not int or item['id'] <= 0:
                            raise ValueError('Invalid relay message')
                        try:
                            reply = self.process(item.get('frame', {}))
                        except Exception:
                            reply = None
                        if reply:
                            client.call('send', frame=reply)
                        client.call('ack', message=item['id'])
                        self.last_contact, self.error = time.time(), ''
            except Exception:
                with self.lock:
                    self.error = 'Relay disconnected. Reconnecting; local CORPORA remains available.'
                self.stopped.wait(delay)
                delay = min(30, delay * 2)
            finally:
                if client:
                    client.close()
