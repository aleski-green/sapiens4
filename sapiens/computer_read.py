"""Bounded, paginated reads over the unchanged Blindly CLI."""
from pathlib import Path
from uuid import uuid4
import argparse
import json
import re
import time


FIELDS = {'path', 'pid', 'role', 'subrole', 'title', 'description', 'value',
          'identifier', 'enabled', 'focused', 'selected', 'actions'}


def compact(node):
    return {k: v for k, v in node.items() if k in FIELDS and v not in ('', None, [])}


def flatten(node, path=''):
    yield {'path': path, **compact(node)}
    for i, child in enumerate(node.get('children', [])):
        yield from flatten(child, f'{path}.{i}' if path else str(i))


def page(snapshot, offset, limit):
    rows = snapshot['nodes']
    if not 0 <= offset <= len(rows):
        raise ValueError('Offset outside snapshot')
    result = {k: v for k, v in snapshot.items() if k != 'nodes'}
    result.update(nodes=[], offset=offset, total=len(rows), next_offset=None)
    for row in rows[offset:]:
        if len(json.dumps({**result, 'nodes': [*result['nodes'], row]}, ensure_ascii=False)) > limit:
            if not result['nodes']:
                # Always make progress on a single large message; disclose clipping.
                row = {k: v[:max(80, limit//8)] if isinstance(v, str) and k != 'path' else v for k,v in row.items()}
                row['text_truncated'] = True
                result['nodes'].append(row)
            break
        result['nodes'].append(row)
    end = offset + len(result['nodes'])
    result['next_offset'] = end if end < len(rows) else None
    return result


def read(argv, invoke, directory, limit):
    parser = argparse.ArgumentParser(prog='computer.py read')
    parser.add_argument('--pid', type=int)
    parser.add_argument('--path', default='')
    parser.add_argument('--depth', type=int, default=12)
    parser.add_argument('--snapshot')
    parser.add_argument('--offset', type=int, default=0)
    args = parser.parse_args(argv)
    cache = Path(directory) / '.computer-reads'
    cache.mkdir(exist_ok=True)
    for old in cache.glob('*.json'):
        if time.time() - old.stat().st_mtime > 90:
            old.unlink(missing_ok=True)
    if args.snapshot:
        if not re.fullmatch('[a-f0-9]{32}', args.snapshot):
            raise ValueError('Invalid snapshot')
        path = cache / (args.snapshot + '.json')
        if not path.exists():
            raise ValueError('Snapshot expired; read the current state again')
        snapshot = json.loads(path.read_text())
    else:
        if args.pid is None or args.pid <= 0 or not re.fullmatch(r'(?:\d+(?:\.\d+)*)?', args.path):
            raise ValueError('Read needs a positive --pid and an observed numeric --path')
        if not 1 <= args.depth <= 30 or args.offset:
            raise ValueError('Depth must be 1–30; paginate using --snapshot')
        depth = (len(args.path.split('.')) if args.path else 0) + args.depth
        if depth > 64:
            raise ValueError('Total depth exceeds 64')
        # Blindly has no subtree-read command. Read once, filter locally, retain
        # exact original paths. Hard node/time bounds still apply before filtering.
        result = invoke(['tree', '--pid', str(args.pid), '--depth', str(depth), '--max-nodes', '5000'])
        if result.returncode:
            raise ValueError(f'Blindly read failed ({result.returncode}): {result.stderr[:300]}')
        data = json.loads(result.stdout)
        nodes = [r for r in flatten(data['tree']) if not args.path or r['path'] == args.path or r['path'].startswith(args.path+'.')]
        if not nodes:
            raise ValueError('Target missing from bounded tree; rediscover it. Coverage is incomplete.')
        # Omit anonymous layout containers, retain target + semantic text/actions.
        nodes = [r for r in nodes if r['path'] == args.path or any(r.get(k) for k in ('title','description','value','identifier','actions'))]
        snapshot = dict(snapshot=uuid4().hex, observed_at=time.time(), pid=args.pid,
            path=args.path, nodes=nodes, truncated=data.get('truncated',False),
            coverage='Bounded accessibility snapshot, not proof of latest/all messages; depth and 5000-node limits apply.')
        for old in sorted(cache.glob('*.json'), key=lambda p:p.stat().st_mtime, reverse=True)[4:]:
            old.unlink(missing_ok=True)
        (cache / (snapshot['snapshot']+'.json')).write_text(json.dumps(snapshot))
    return page(snapshot, args.offset, limit)
