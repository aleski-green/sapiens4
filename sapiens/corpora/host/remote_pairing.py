"""MVP NaCl boxes and strict framing; no secrets are sent to the relay in plaintext."""
import base64
import hashlib
import json
import secrets
import time
from urllib.parse import urlsplit

try:
    from nacl.public import Box, PrivateKey, PublicKey
except ImportError:  # Local CORPORA does not require the optional remote dependency.
    Box = PrivateKey = PublicKey = None

MAX_FRAME = 512_000
PROTOCOL = 'sapiens-remote-box-v1'


def available():
    return Box is not None


def b64(raw):
    return base64.b64encode(bytes(raw)).decode('ascii')


def unb64(value, length=None):
    if not isinstance(value, str) or len(value) > MAX_FRAME:
        raise ValueError('Invalid encoded value')
    result = base64.b64decode(value, validate=True)
    if length is not None and len(result) != length:
        raise ValueError('Invalid key or nonce length')
    return result


def keypair():
    if not available():
        raise ValueError('Install sapiens/corpora/host/remote-requirements.txt to enable remote access')
    key = PrivateKey.generate()
    return b64(key), b64(key.public_key)


def token():
    return secrets.token_urlsafe(32)


def fingerprint(public):
    return hashlib.sha256(unb64(public, 32)).hexdigest()[:32]


def origin(value):
    if not isinstance(value, str):
        raise ValueError('Relay must be an HTTPS origin')
    parts = urlsplit(value)
    if (parts.scheme not in {'https', 'http'} or not parts.hostname or
            parts.username or parts.password or parts.path not in {'', '/'} or
            parts.query or parts.fragment or
            (parts.scheme == 'http' and parts.hostname not in {'127.0.0.1', 'localhost', '::1'})):
        raise ValueError('Use an HTTPS relay origin (HTTP is allowed only on loopback for testing)')
    if parts.port is not None and not 1 <= parts.port <= 65535:
        raise ValueError('Invalid relay port')
    return value.rstrip('/')


def pack(secret, peer, room, direction, payload):
    body = dict(v=PROTOCOL, room=room, direction=direction, **payload)
    raw = json.dumps(body, separators=(',', ':'), allow_nan=False).encode()
    if len(raw) > 300_000:
        raise ValueError('Remote response is too large')
    message = Box(PrivateKey(unb64(secret, 32)), PublicKey(unb64(peer, 32))).encrypt(raw)
    return dict(sender=b64(PrivateKey(unb64(secret, 32)).public_key),
                nonce=b64(message.nonce), ciphertext=b64(message.ciphertext))


def unpack(secret, peer, room, direction, frame):
    if frame.get('sender') != peer:
        raise ValueError('Unexpected sender')
    raw = Box(PrivateKey(unb64(secret, 32)), PublicKey(unb64(peer, 32))).decrypt(
        unb64(frame.get('ciphertext')), unb64(frame.get('nonce'), 24))
    body = json.loads(raw)
    if (not isinstance(body, dict) or body.get('v') != PROTOCOL or
            body.get('room') != room or body.get('direction') != direction):
        raise ValueError('Wrong message context')
    if (not isinstance(body.get('id'), str) or not 1 <= len(body['id']) <= 80 or
            type(body.get('expires')) not in (int, float) or
            not time.time() < body['expires'] <= time.time() + 86400):
        raise ValueError('Expired or invalid message')
    return body
