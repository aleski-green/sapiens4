"""Self-hosted opaque mailboxes. Run behind HTTPS; never imports the Sapiens runtime."""
import argparse
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import time
from urllib.parse import urlsplit

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


class RelayServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, path, admin, public_origin):
        if len(admin) < 32 or not admin.isascii():
            raise ValueError('SAPIENS_RELAY_ADMIN_TOKEN must contain at least 32 ASCII characters')
        self.mailboxes, self.admin = Mailboxes(path), admin
        self.public_origin = origin(public_origin)
        self.last_sweep = 0
        super().__init__(address, RelayHandler)


    def service_actions(self):
        if time.time() - self.last_sweep >= 60:
            with self.mailboxes.connect() as db:
                now = time.time()
                db.execute('DELETE FROM messages WHERE expires <= ? OR room IN '
                           '(SELECT id FROM rooms WHERE expires <= ?)', (now, now))
                db.execute('DELETE FROM rooms WHERE expires <= ?', (now,))
            self.last_sweep = time.time()


class RelayHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # No URLs, request bodies, bearer tokens, or exception details in access logs.

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def send(self, status, body, mime='application/json'):
        raw = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        for key, value in {
            'Content-Type': mime + '; charset=utf-8', 'Content-Length': str(len(raw)),
            'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
            'Referrer-Policy': 'no-referrer', 'X-Frame-Options': 'DENY',
            'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
                "connect-src 'self'; img-src 'self' blob: data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        }.items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(raw)

    def handle_request(self):
        try:
            path = urlsplit(self.path).path
            if self.headers.get('Host') != urlsplit(self.server.public_origin).netloc:
                raise RelayError(403, 'Unexpected host')
            request_origin = self.headers.get('Origin')
            if request_origin and request_origin != self.server.public_origin:
                raise RelayError(403, 'Unexpected origin')
            if self.command == 'GET' and path in ASSETS:
                name, mime = ASSETS[path]
                return self.send(200, (ROOT / 'web' / name).read_bytes(), mime)
            # Static CORPORA code is public; no application data is served by this host.
            if self.command == 'GET' and path in {'/workspace/', '/workspace/app.js',
                    '/workspace/styles.css', '/live.css', '/assets/sapi-theme.css', '/assets/sapi-theme.js'}:
                found = asset(path)
                return self.send(200, found[1], found[0].split(';')[0])
            body = {}
            if self.command == 'POST':
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= MAX_FRAME or self.headers.get_content_type() != 'application/json':
                    raise RelayError(413, 'Invalid body size or content type')
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict):
                    raise RelayError(400, 'Expected object')
            authorization = self.headers.get('Authorization', '')
            if not re.fullmatch(r'Bearer [\x21-\x7e]{1,256}', authorization):
                raise RelayError(401, 'Bearer token required')
            result = self.server.mailboxes.transact(self.command, path.strip('/').split('/'),
                                                   authorization[7:], body, self.server.admin)
            self.send(200, result)
        except RelayError as error:
            self.send(error.status, dict(error=str(error)))
        except (ValueError, TypeError, KeyError):
            self.send(400, dict(error='Invalid request'))
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except Exception:
            self.send(500, dict(error='Relay unavailable'))

    do_GET = do_POST = do_DELETE = handle_request


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
