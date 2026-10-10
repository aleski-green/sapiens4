"""Private relay connection files, shared by relay setup and desktop pairing."""
import json
import secrets
from urllib.parse import urlsplit

from sapiens.files import atomic_json
from sapiens.paths import ROOT
from sapiens.corpora.host.remote_pairing import origin

LOCAL_CONNECTION = ROOT / '.sapiens4' / 'relay.connection.json'
FORMAT = 'sapiens-relay-connection-v1'


def validate(value):
    if not isinstance(value, dict) or value.get('format') != FORMAT:
        raise ValueError('Choose a Sapiens relay connection file')
    relay, token = origin(value.get('relay')), value.get('token')
    if not isinstance(token, str) or not 32 <= len(token) <= 256 or any(
            not 33 <= ord(char) <= 126 for char in token):
        raise ValueError('Invalid relay provisioning token')
    return dict(format=FORMAT, relay=relay, token=token)


def read(path):
    with path.open('rb') as stream:
        raw = stream.read(4097)
    if len(raw) > 4096:
        raise ValueError('Relay connection file is too large')
    return validate(json.loads(raw))


def provision(path, public_origin, token=''):
    # Preserve the credential across restarts; an explicit environment value rotates it.
    if not token and path.exists():
        token = read(path)['token']
    value = validate(dict(format=FORMAT, relay=public_origin, token=token or secrets.token_urlsafe(32)))
    atomic_json(path, value)
    return value


def local_connection():
    try:
        value = read(LOCAL_CONNECTION)
        url = urlsplit(value['relay'])
        if url.scheme == 'http' and url.hostname in {'127.0.0.1', 'localhost', '::1'}:
            return value
    except (OSError, ValueError, TypeError):
        pass
    return None
