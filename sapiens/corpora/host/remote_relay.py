"""Self-hosted opaque mailboxes. Run behind HTTPS; never imports the Sapiens runtime."""
import argparse
import asyncio
import contextlib
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import socket
import threading
import time
from urllib.parse import urlsplit

from aiohttp import web, WSMsgType

from sapiens.corpora.host.remote_pairing import MAX_FRAME, origin, unb64
from sapiens.paths import ROOT
from sapiens.corpora.host.assets import asset
from sapiens.corpora.host.remote_setup import provision

ASSETS = {
    '/': ('shell/remote.html', 'text/html'),
    '/remote.js': ('features/remote.js', 'text/javascript'),
    '/remote-vendor.js': ('features/remote-vendor.js', 'text/javascript'),
    '/remote.css': ('theme/remote.css', 'text/css'),
}


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class RelayError(Exception):
    def __init__(self, status, message):
        self.status = status
        super().__init__(message)


class Mailboxes:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS rooms
                (id TEXT PRIMARY KEY, desktop TEXT, phone TEXT, expires REAL);
                CREATE TABLE IF NOT EXISTS messages
                (id INTEGER PRIMARY KEY AUTOINCREMENT, room TEXT, recipient TEXT,
                 body TEXT, expires REAL);
                CREATE INDEX IF NOT EXISTS inbox ON messages(room, recipient, id);
            ''')

    def connect(self):
        return sqlite3.connect(self.path, timeout=10)

    def transact(self, method, parts, bearer, body, admin):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            now = time.time()
            db.execute('DELETE FROM messages WHERE expires <= ? OR room IN '
                       '(SELECT id FROM rooms WHERE expires <= ?)', (now, now))
            db.execute('DELETE FROM rooms WHERE expires <= ?', (now,))
            if parts == ['api', 'rooms'] and method == 'POST':
                if not hmac.compare_digest(bearer, admin):
                    raise RelayError(401, 'Unauthorized')
                if db.execute('SELECT count(*) FROM rooms').fetchone()[0] >= 100:
                    raise RelayError(429, 'Room limit reached')
                room, desktop, phone = [secrets.token_urlsafe(32) for _ in range(3)]
                db.execute('INSERT INTO rooms VALUES (?, ?, ?, ?)',
                           (room, digest(desktop), digest(phone), now + 7 * 86400))
                return dict(room=room, desktop=desktop, phone=phone)
            if len(parts) < 3 or parts[:2] != ['api', 'rooms']:
                raise RelayError(404, 'Not found')
            room = parts[2]
            row = db.execute('SELECT desktop, phone FROM rooms WHERE id=?', (room,)).fetchone()
            key = digest(bearer)
            role = ('desktop' if row and hmac.compare_digest(key, row[0]) else
                    'phone' if row and hmac.compare_digest(key, row[1]) else None)
            if not role:
                raise RelayError(401, 'Unknown or expired mailbox')
            if len(parts) == 3 and method == 'DELETE' and role == 'desktop':
                db.execute('DELETE FROM messages WHERE room=?', (room,))
                db.execute('DELETE FROM rooms WHERE id=?', (room,))
                return dict(deleted=True)
            if len(parts) == 4 and parts[3] == 'messages':
                if method == 'GET':
                    rows = db.execute('SELECT id, body FROM messages WHERE room=? AND recipient=? '
                                      'ORDER BY id LIMIT 20', (room, role)).fetchall()
                    messages, size = [], 0
                    for id_, raw in rows:
                        if messages and size + len(raw) > MAX_FRAME:
                            break
                        messages.append(dict(id=id_, frame=json.loads(raw)))
                        size += len(raw)
                    return dict(messages=messages)
                if method == 'POST':
                    if set(body) != {'sender', 'nonce', 'ciphertext'}:
                        raise RelayError(400, 'Expected an encrypted frame')
                    unb64(body['sender'], 32)
                    unb64(body['nonce'], 24)
                    if len(unb64(body['ciphertext'])) < 16:
                        raise RelayError(400, 'Invalid ciphertext')
                    raw = json.dumps(body, separators=(',', ':'))
                    count, size = db.execute('SELECT count(*), coalesce(sum(length(body)),0) '
                                             'FROM messages WHERE room=?', (room,)).fetchone()
                    if count >= 100 or size + len(raw) > 48_000_000:
                        raise RelayError(429, 'Mailbox full')
                    recipient = 'phone' if role == 'desktop' else 'desktop'
                    cursor = db.execute('INSERT INTO messages(room,recipient,body,expires) VALUES(?,?,?,?)',
                                        (room, recipient, raw, now + 86400))
                    return dict(id=cursor.lastrowid)
            if len(parts) == 5 and parts[3] == 'messages' and method == 'DELETE':
                if not parts[4].isdigit():
                    raise RelayError(400, 'Invalid message ID')
                db.execute('DELETE FROM messages WHERE id=? AND room=? AND recipient=?',
                           (parts[4], room, role))
                return dict(deleted=True)
            raise RelayError(404, 'Not found')


class RelayServer:
    """One HTTP/WebSocket listener; ciphertext is committed before delivery."""
    def __init__(self, address, path, admin, public_origin):
        if len(admin) < 32 or not admin.isascii():
            raise ValueError('SAPIENS_RELAY_ADMIN_TOKEN must contain at least 32 ASCII characters')
        self.mailboxes, self.admin = Mailboxes(path), admin
        self.public_origin = origin(public_origin)
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(address)
        self.socket.listen(128)
        self.server_port = self.socket.getsockname()[1]
        self.loop = None
        self.started, self.finished = threading.Event(), threading.Event()
        self.listeners, self.connections = {}, set()

    def transact(self, method, parts, bearer, body=None):
        result = self.mailboxes.transact(method, parts, bearer, body or {}, self.admin)
        if method != 'GET' and len(parts) >= 3:
            for event in self.listeners.get(parts[2], ()):
                event.set()
        return result

    def response(self, status, body, mime='application/json'):
        raw = body if isinstance(body, bytes) else json.dumps(body).encode()
        ws_origin = ('wss' if self.public_origin.startswith('https:') else 'ws') + self.public_origin[self.public_origin.index(':'):]
        return web.Response(status=status, body=raw, headers={
            'Content-Type': mime + '; charset=utf-8', 'Cache-Control': 'no-store',
            'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'X-Frame-Options': 'DENY',
            'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
                "connect-src 'self' " + ws_origin + "; img-src 'self' blob: data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        })

    async def handle(self, req):
        try:
            if req.headers.get('Host') != urlsplit(self.public_origin).netloc:
                raise RelayError(403, 'Unexpected host')
            request_origin = req.headers.get('Origin')
            if request_origin and request_origin != self.public_origin:
                raise RelayError(403, 'Unexpected origin')
            path = req.path
            if req.method == 'GET' and path == '/api/socket':
                if req.query_string or request_origin != self.public_origin:
                    raise RelayError(403, 'WebSocket requires the relay origin and no query credentials')
                return await self.websocket(req)
            if req.method == 'GET' and path in ASSETS:
                name, mime = ASSETS[path]
                return self.response(200, (ROOT / 'web' / name).read_bytes(), mime)
            if req.method == 'GET' and path in {'/workspace/', '/workspace/app.js',
                    '/workspace/styles.css', '/live.css', '/assets/sapi-theme.css', '/assets/sapi-theme.js'}:
                found = asset(path)
                return self.response(200, found[1], found[0].split(';')[0])
            body = {}
            if req.method == 'POST':
                if not 0 < (req.content_length or 0) <= MAX_FRAME or req.content_type != 'application/json':
                    raise RelayError(413, 'Invalid body size or content type')
                body = await asyncio.wait_for(req.json(), 10)
                if not isinstance(body, dict):
                    raise RelayError(400, 'Expected object')
            authorization = req.headers.get('Authorization', '')
            if not re.fullmatch(r'Bearer [\x21-\x7e]{1,256}', authorization):
                raise RelayError(401, 'Bearer token required')
            result = self.transact(req.method, path.strip('/').split('/'), authorization[7:], body)
            return self.response(200, result)
        except RelayError as error:
            return self.response(error.status, dict(error=str(error)))
        except (ValueError, TypeError, KeyError):
            return self.response(400, dict(error='Invalid request'))
        except Exception:
            return self.response(500, dict(error='Relay unavailable'))

    async def websocket(self, req):
        if len(self.connections) >= 128:
            raise RelayError(429, 'Connection limit reached')
        ws = web.WebSocketResponse(heartbeat=25, max_msg_size=MAX_FRAME + 4096, compress=False)
        self.connections.add(ws)
        room, event, delivery = None, asyncio.Event(), None
        try:
            await ws.prepare(req)
            auth = await ws.receive_json(timeout=10)
            if (not isinstance(auth, dict) or auth.get('type') != 'auth' or
                    not isinstance(auth.get('room'), str) or not re.fullmatch(r'[A-Za-z0-9_-]{32,64}', auth['room']) or
                    not isinstance(auth.get('token'), str) or not re.fullmatch(r'[\x21-\x7e]{32,256}', auth['token'])):
                raise RelayError(401, 'Invalid mailbox authentication')
            room, bearer = auth['room'], auth['token']
            path = ['api', 'rooms', room, 'messages']
            self.transact('GET', path, bearer)
            if len(self.listeners.get(room, ())) >= 4:
                raise RelayError(429, 'Mailbox connection limit reached')
            self.listeners.setdefault(room, set()).add(event)
            await ws.send_json(dict(type='ready'))
            # At most one bounded batch is in flight. Unacknowledged frames remain
            # in SQLite and are replayed on reconnect, never in an unbounded RAM queue.
            in_flight = set()

            async def deliver():
                while not ws.closed:
                    await event.wait()
                    event.clear()
                    try:
                        result = self.transact('GET', path, bearer)
                        # Expired frames no longer block subsequent deliveries.
                        with self.mailboxes.connect() as db:
                            live = {row[0] for row in db.execute('SELECT id FROM messages WHERE room=?', (room,))}
                        in_flight.intersection_update(live)
                        if not in_flight and result['messages']:
                            in_flight.update(item['id'] for item in result['messages'])
                            await asyncio.wait_for(ws.send_json(dict(type='messages', **result)), 10)
                    except RelayError:
                        await ws.close(code=4001, message=b'Mailbox expired or revoked')
                        return
                    except Exception:
                        await ws.close(code=1011)
                        return

            delivery = asyncio.create_task(deliver())
            event.set()
            async for incoming in ws:
                if incoming.type != WSMsgType.TEXT:
                    break
                value = json.loads(incoming.data)
                if not isinstance(value, dict):
                    raise ValueError('Expected object')
                id_ = value.get('id')
                if not isinstance(id_, str) or not 1 <= len(id_) <= 64:
                    raise ValueError('Invalid request ID')
                try:
                    if value.get('type') == 'send' and isinstance(value.get('frame'), dict):
                        if len(json.dumps(value['frame'])) > MAX_FRAME:
                            raise RelayError(413, 'Frame too large')
                        result = self.transact('POST', path, bearer, value['frame'])
                    elif value.get('type') == 'ack' and type(value.get('message')) is int and value['message'] > 0:
                        result = self.transact('DELETE', path + [str(value['message'])], bearer)
                        in_flight.discard(value['message'])
                    else:
                        raise RelayError(400, 'Unsupported socket operation')
                    await asyncio.wait_for(ws.send_json(dict(type='result', id=id_, result=result)), 10)
                except RelayError as error:
                    await ws.send_json(dict(type='result', id=id_, error=str(error)))
        except (ValueError, TypeError, KeyError, RelayError, asyncio.TimeoutError):
            if ws.prepared:
                await ws.close(code=4001, message=b'Invalid or expired mailbox request')
        finally:
            if delivery:
                delivery.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await delivery
            if room in self.listeners:
                self.listeners[room].discard(event)
                if not self.listeners[room]:
                    del self.listeners[room]
            self.connections.discard(ws)
            if ws.prepared:
                await ws.close()
        return ws

    async def sweep(self):
        while True:
            await asyncio.sleep(60)
            with self.mailboxes.connect() as db:
                now = time.time()
                db.execute('DELETE FROM messages WHERE expires <= ? OR room IN '
                           '(SELECT id FROM rooms WHERE expires <= ?)', (now, now))
                db.execute('DELETE FROM rooms WHERE expires <= ?', (now,))
            for events in self.listeners.values():
                for event in events:
                    event.set()  # Recheck expiry for already-open sockets too.

    async def run(self):
        self.loop = asyncio.get_running_loop()
        self.stop_event = asyncio.Event()
        app = web.Application(client_max_size=MAX_FRAME)
        app.router.add_route('*', '/{path:.*}', self.handle)
        runner = web.AppRunner(app, access_log=None, shutdown_timeout=5)
        await runner.setup()
        await web.SockSite(runner, self.socket).start()
        sweep = asyncio.create_task(self.sweep())
        self.started.set()
        try:
            await self.stop_event.wait()
        finally:
            sweep.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await sweep
            await asyncio.gather(*(ws.close(code=1001) for ws in list(self.connections)))
            await runner.cleanup()

    def serve_forever(self):
        try:
            asyncio.run(self.run())
        finally:
            self.finished.set()

    def shutdown(self):
        if self.started.wait(5) and self.loop and self.loop.is_running():
            self.loop.call_soon_threadsafe(self.stop_event.set)
            self.finished.wait(10)

    def server_close(self):
        self.socket.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=4180)
    parser.add_argument('--db', type=Path, default=Path('.sapiens4/relay.sqlite3'))
    parser.add_argument('--origin', required=True, help='Public HTTPS origin, or loopback HTTP for tests')
    parser.add_argument('--connection-file', type=Path,
                        help='Private connection file to import in CORPORA (default: beside database)')
    args = parser.parse_args()
    connection_path = args.connection_file or args.db.with_suffix('.connection.json')
    connection = provision(connection_path, args.origin, os.environ.get('SAPIENS_RELAY_ADMIN_TOKEN', ''))
    server = RelayServer((args.bind, args.port), args.db,
                         connection['token'], connection['relay'])
    print('Relay connection file: ' + str(connection_path.resolve()), flush=True)
    print('In desktop CORPORA → Connect phone → Import relay connection file. '
          'Keep this file private; it contains the provisioning token.', flush=True)
    print('Remote relay ready. Configure HTTPS and proxy limits before internet exposure.', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
