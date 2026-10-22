"""Permanent CORPORA identity, independent of processes and relay invitations."""
import json
import hashlib
from uuid import UUID, uuid4

from sapiens.files import atomic_json, file_lock


def public_id(identity):
    """Stable, non-secret address; the relay rejects address collisions."""
    value = int.from_bytes(hashlib.sha256(UUID(identity).bytes).digest(), 'big') % (26 ** 6 * 1000)
    suffix = ''
    for index in reversed(range(9)):
        alphabet = '0123456789' if 3 <= index < 6 else 'abcdefghijklmnopqrstuvwxyz'
        value, digit = divmod(value, len(alphabet))
        suffix = alphabet[digit] + suffix
    return 'sapi4_' + suffix


def corpora_id(root):
    path = root / 'corpora-identity.json'
    with file_lock(root / 'corpora-identity.lock'):
        if not path.exists():
            atomic_json(path, {'version': 1, 'corpora_id': str(uuid4())})
        try:
            value = json.loads(path.read_text())
            identity = value['corpora_id']
            if value['version'] != 1 or str(UUID(identity)) != identity:
                raise ValueError('Invalid identity')
            return identity
        except (ValueError, TypeError, KeyError, AttributeError) as error:
            raise ValueError('Invalid CORPORA identity. Restore corpora-identity.json from backup.') from error
