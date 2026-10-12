"""Permanent CORPORA identity, independent of processes and relay invitations."""
import json
from uuid import UUID, uuid4

from sapiens.files import atomic_json, file_lock


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
