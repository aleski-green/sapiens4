"""Small launch-only helper; all UI observation and interaction stays in Blindly4."""
import json
import subprocess
import sys

try:
    from .computer_read import compact, read
except ImportError:
    from computer_read import compact, read
from pathlib import Path


def bounded_output(text, limit):
    try:
        value = json.loads(text)
    except ValueError:
        value = None
    if isinstance(value, dict) and isinstance(value.get('tree'), dict):
        nodes = []
        def walk(node, path=''):
            row = {k: v for k, v in node.items() if k in {'role','subrole','title','description','value','identifier','enabled','focused','selected'} and v not in ('', None)}
            nodes.append({'path': path, **row})
            for i, child in enumerate(node.get('children', [])):
                walk(child, f'{path}.{i}' if path else str(i))
        walk(value['tree'])
        value = dict(pid=value['tree'].get('pid'), nodes=nodes,
                     truncated=value.get('truncated', False), coverage='Bounded AX tree; depth and node limits apply')
        # Keep complete rows and exact paths when truncating; never manufacture
        # paths from a filtered child index. The traversal above uses original indices.
        while len(json.dumps(value, ensure_ascii=False, separators=(',', ':'))) > limit and nodes:
            nodes.pop()
            value['truncated'] = True
        return json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    if isinstance(value, dict) and isinstance(value.get('matches'), list):
        value['matches'] = [compact(row) for row in value['matches']]
        while len(json.dumps(value, ensure_ascii=False)) > limit and value['matches']:
            value['matches'].pop()
            value['truncated'] = True
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, dict) and 'role' in value:
        value = compact(value)
    if value is not None:
        text = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    if len(text) <= limit:
        return text
    return json.dumps(dict(truncated=True, output_excerpt=text[:limit],
        hint='Partial observation only. Use find or inspect for the relevant element; do not repeat this full dump.'))


def main(argv):
    if argv and argv[0] in {'blindly', 'read'}:
        binary = Path(__file__).resolve().parent.parent / 'blindly4/.build/release/blindly4'
        settings = Path.cwd() / 'computer-limits.json'
        limit = json.loads(settings.read_text()).get('output_chars', 4800) if settings.exists() else 4800
        limit = max(800, min(32000, int(limit)))
        Path('.computer-used').touch()
        def invoke(args):
            return subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=30)
        if argv[0] == 'read':
            print(json.dumps(read(argv[1:], invoke, Path.cwd(), limit), ensure_ascii=False))
            return 0
        result = invoke(argv[1:])
        print(bounded_output(result.stdout, limit))
        if result.stderr:
            print(result.stderr[:2000], file=sys.stderr)
        return result.returncode
    if len(argv) != 2 or argv[0] != 'launch' or not argv[1].strip() or argv[1].startswith('-') or len(argv[1]) > 120:
        raise ValueError('Usage: computer.py launch "Application Name"')
    if sys.platform != 'darwin':
        raise ValueError('App launch requires macOS')
    Path('.computer-used').touch()
    result = subprocess.run(['/usr/bin/open', '-a', argv[1]], capture_output=True, text=True, timeout=15)
    print(json.dumps(dict(launched=result.returncode == 0, app=argv[1], error=result.stderr.strip() or None)))
    return result.returncode


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, subprocess.TimeoutExpired) as error:
        print(json.dumps({'error': str(error)}))
        sys.exit(1)
