from contextlib import contextmanager
import hashlib
import hmac
import json
import os
import sqlite3
import threading
import time
from urllib.parse import urlsplit
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from sapiens.corpora.host.corpora_api import dispatch
from sapiens.files import atomic_json
from sapiens.corpora.host.identity import public_id
from sapiens.corpora.host import remote_pairing as crypto
from sapiens.corpora.host.remote_setup import FORMAT, local_connection, read as read_connection, validate as validate_connection
from sapiens.corpora.host.remote_socket import SocketClient, websocket
from sapiens.validation import APIError


class RelayRequestError(ValueError):
    def __init__(self, status):
        self.status = status
        super().__init__('Relay request failed (HTTP %s)' % status)


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
        raise RelayRequestError(error.code) from None


class RemoteBridge:
    def __init__(self, service):
        self.service = service
        self.path = service.root / 'remote-device.json'
        self.relay_path = service.root / 'remote-relay.json'
        self.receipts = service.root / 'remote-receipts.sqlite3'
        self.lock, self.stopped = threading.RLock(), threading.Event()
        self.config = None
        self.error, self.last_contact = '', None
        if self.path.exists():
            try:
                config = json.loads(self.path.read_text())
                identity = service.projection.corpora_identity()['id']
                if not isinstance(config, dict):
                    raise ValueError('Invalid saved pairing')
                if config.get('corpora_id', identity) != identity:
                    raise ValueError('Pairing belongs to another CORPORA')
                crypto.origin(config['relay'])
                crypto.unb64(config['private'], 32)
                crypto.unb64(config['public'], 32)
                if config.get('peer'):
                    crypto.unb64(config['peer'], 32)
                if (not isinstance(config['room'], str) or not isinstance(config['token'], str) or
                        type(config['expires']) not in (int, float)):
                    raise ValueError('Invalid saved pairing')
                self.config = config
                config['corpora_id'] = identity
                self.save()
            except (OSError, ValueError, TypeError, KeyError):
                self.config = None
                self.error = 'Saved remote pairing is invalid. Create a new pairing; local CORPORA is unaffected.'
        self.connections = {self.config.get('last_connection_id')} if self.config else set()
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
            corpora = self.service.projection.corpora_identity()
            return dict(available=crypto.available() and websocket is not None, enabled=bool(config),
                        corpora=corpora, public_id=public_id(corpora['id']),
                        invitation=config.get('invitation') if not config.get('peer') and config.get('expires', 0) > time.time() else None,
                        local_relay=bool(local_connection()),
                        configured_relay=self.saved_relay().get('relay'),
                        paired=bool(config.get('peer')), relay=config.get('relay'),
                        paired_at=config.get('paired_at'), last_connected_at=config.get('last_connected_at'),
                        device_info=config.get('device_info', {}),
                        fingerprint=crypto.fingerprint(config['peer']) if config.get('peer') else None,
                        pending=dict(fingerprint=crypto.fingerprint(pending['peer']), peer=pending['peer'],
                                     confirmation_code=crypto.confirmation_code(config['public'], pending['peer'], config['room']))
                        if pending and config['expires'] > time.time() else None,
                        expires=config.get('expires'), error=self.error, last_contact=self.last_contact)

    def saved_relay(self):
        try:
            return read_connection(self.relay_path)
        except (OSError, ValueError, TypeError):
            return {}

    def create(self, data):
        if websocket is None:
            raise ValueError('Install libs4/python/remote-requirements.txt to enable WebSocket remote access')
        if data.get('local') is True:
            data = local_connection()
            if not data:
                raise ValueError('Local test relay setup is missing. Start the relay or import its connection file.')
        elif data.get('saved') is True:
            data = self.saved_relay()
            if not data:
                raise ValueError('Configure your relay once before connecting a phone.')
        connection = validate_connection(dict(format=FORMAT, relay=data.get('relay'), token=data.get('token'), beta=data.get('beta')))
        relay, admin = connection['relay'], connection.get('token', '')
        private, public = crypto.keypair()
        with self.lock:
            if self.config:
                raise ValueError('Revoke the existing pairing before creating another')
            identity = self.service.projection.corpora_identity()['id']
            address = public_id(identity)
            room = request(relay, '/beta/api/rooms' if connection.get('beta') else '/api/rooms', admin, 'POST', dict(
                public_id=address, corpora_id=identity, public_key=public))
            if any(not isinstance(room.get(k), str) or not 32 <= len(room[k]) <= 64 or
                   any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in room[k])
                   for k in ('room', 'desktop', 'phone')):
                raise ValueError('Invalid relay mailbox')
            self.error = ''
            secret = crypto.token()
            expires = time.time() + crypto.PAIRING_TTL
            invitation = dict(v=crypto.PROTOCOL, relay=relay, room=room['room'], token=room['phone'],
                              desktop=public, secret=secret, expires=expires, public_id=address)
            self.config = dict(relay=relay, room=room['room'], token=room['desktop'],
                               corpora_id=identity,
                               private=private, public=public, secret=secret, expires=expires,
                               peer=None, pending=None, invitation=invitation)
            self.save()
            atomic_json(self.relay_path, connection)
            self.start()
            # The provisioning token and desktop private key are never placed in the QR.
            return dict(qr=invitation)

    def approve(self, data):
        with self.lock:
            config = self.config
            pending = config.get('pending') if config else None
            if not pending or config['expires'] <= time.time() or data.get('peer') != pending['peer']:
                raise ValueError('Pairing expired or phone changed; generate a new QR')
            # Only the desktop can make an invited mailbox persistent. Phone access
            # still requires the explicitly approved encryption key below.
            request(config['relay'], '/api/rooms/' + config['room'] + '/trust',
                    config['token'], 'POST', {})
            config['peer'] = pending['peer']
            config['paired_at'] = time.time()
            config['device_info'] = pending.get('device_info', {})
            config['accept'] = self.response(pending['id'], dict(paired=True, corpora=self.service.projection.corpora_identity()))
            config['pending'] = None
            config.pop('secret', None)
            config.pop('invitation', None)
            self.save()
            return dict(approved=True)

    def revoke(self, notify=True):
        with self.lock:
            config, self.config = self.config, None
            self.save()  # Local revocation takes effect even if relay is unreachable.
            self.error, self.last_contact = '', None
        deleted = None if config else True
        if config and notify:
            deleted = self.delete_room(config)
        return dict(revoked=True, relay_deleted=deleted)

    @staticmethod
    def delete_room(config):
        try:
            request(config['relay'], '/api/rooms/' + config['room'], config['token'], 'DELETE')
        except RelayRequestError as error:
            return error.status in {401, 404}  # Already removed or expired.
        except Exception:
            return False
        return True

    def close(self):
        self.stopped.set()
        if self.thread:
            self.thread.join()

    @contextmanager
    def connect(self):
        if not self.receipts.exists():
            fd = os.open(self.receipts, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
        db = sqlite3.connect(self.receipts)
        try:
            with db:
                db.execute('CREATE TABLE IF NOT EXISTS receipts (room TEXT, id TEXT, hash TEXT, reply TEXT, '
                           'created REAL, PRIMARY KEY(room,id))')
                yield db
        finally:
            db.close()  # SQLite's transaction context does not close the connection.

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
            config['pending'] = dict(peer=peer, id=message['id'], device_info=self.device_info(message.get('device_info')))
            self.save()
            return None
        if message.get('kind') != 'request' or message['expires'] > time.time() + 310:
            raise ValueError('Invalid request')
        corpora = self.service.projection.corpora_identity()
        if message.get('corpora_id', corpora['id']) != corpora['id']:
            return self.response(message['id'], dict(error='This device is connected to a different CORPORA. Pair again.'))
        self.record_connection(message)
        if message.get('op') == 'resume':
            return self.response(message['id'], dict(paired=True, corpora=corpora))
        if message.get('op') == 'api' and message.get('method') == 'GET':
            # Reads are safe to repeat; do not retain a full desktop snapshot per poll.
            return self.execute_response(message)
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
        reply = self.execute_response(message)
        with self.connect() as db:
            db.execute('UPDATE receipts SET reply=? WHERE room=? AND id=?',
                       (json.dumps(reply), config['room'], message['id']))
        return reply

    @staticmethod
    def device_info(value):
        if not isinstance(value, dict):
            return {}
        return {key: ''.join(c for c in value[key] if c.isprintable()).strip()[:200]
                for key in ('name', 'platform', 'client') if isinstance(value.get(key), str)}

    def record_connection(self, message):
        # Only authenticated peer traffic reaches here, never relay keepalives.
        config = self.config
        connection = message.get('connection_id')
        if not isinstance(connection, str) or not 1 <= len(connection) <= 100:
            connection = None
        info = self.device_info(message.get('device_info'))
        changed = False
        if (not config.get('last_connected_at') or
                (connection and connection not in self.connections) or
                (not connection and message.get('op') == 'resume')):
            config['last_connected_at'] = time.time()
            config['last_connection_id'] = connection
            self.connections.add(connection)
            if len(self.connections) > 128:
                self.connections = {connection}
            changed = True
        if info and info != config.get('device_info'):
            config['device_info'] = info
            changed = True
        if changed:
            self.save()

    def execute_response(self, message):
        try:
            value = self.execute(message)
        except (ValueError, APIError) as error:
            value = dict(error=str(error))
        except Exception:
            value = dict(error='Local operation failed; check desktop before sending again')
        try:
            return self.response(message['id'], value)
        except ValueError:
            return self.response(message['id'], dict(error='Response too large; inspect on desktop'))

    def execute(self, message):
        if message.get('op') != 'api':
            raise ValueError('Remote operation not allowed')
        method, target = message.get('method'), message.get('path')
        if method not in {'GET', 'POST', 'PUT'} or not isinstance(target, str) or len(target) > 8192:
            raise ValueError('Unsupported remote API request')
        url = urlsplit(target)
        parts = url.path.strip('/').split('/')
        if (url.scheme or url.netloc or url.fragment or not target.startswith('/api/') or
                '%' in url.path or '..' in parts or '\\' in target or
                parts[:2] in (['api', 'remote'], ['api', 'host']) or
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
