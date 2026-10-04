"""Small launch-only helper; all UI observation and interaction stays in Blindly4."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


if __package__:
    from .reader import compact, read
else:  # Support the agent-facing `python /path/to/sapiens/computer/commands.py` command.
    # Embedded Python's isolated ._pth omits the script directory.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from reader import compact, read


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


def acquire():
    config_path = Path.cwd() / 'host-control.json'
    if not config_path.exists():
        return  # Standalone helper outside a managed Sapi workspace.
    config = json.loads(config_path.read_text(encoding='utf-8'))
    request = Request(config['url'], data=b'{"op":"computer_acquire"}', headers={
        'Content-Type': 'application/json', 'X-Sapiens-Local': '1'})
    try:
        with urlopen(request, timeout=20) as response:
            json.load(response)
    except HTTPError as error:
        raise ValueError(json.loads(error.read()).get('error', 'Shared computer unavailable')) from None
    except URLError as error:
        raise ValueError('Cannot reserve the shared computer: ' + str(error.reason)) from None


def main(argv):
    if argv and argv[0] in {'blindly', 'read'}:
        relative = 'blindly4/.build/windows/blindly4.exe' if sys.platform == 'win32' else 'blindly4/.build/release/blindly4'
        binary = Path(os.environ.get('SAPIENS_BLINDLY_BINARY') or Path(__file__).resolve().parents[2] / relative)
        limit = 48000  # Bound individual UI observations; paginate larger subtrees.
        acquire()
        Path('.computer-used').touch()
        def invoke(args):
            return subprocess.run([str(binary), *args], capture_output=True, text=True, encoding='utf-8', timeout=30,
                                  **({'creationflags': subprocess.CREATE_NO_WINDOW} if sys.platform == 'win32' else {}))
        if argv[0] == 'read':
            print(json.dumps(read(argv[1:], invoke, Path.cwd(), limit), ensure_ascii=False))
            return 0
        result = invoke(argv[1:])
        print(bounded_output(result.stdout, limit))
        if result.stderr:
            print(result.stderr[:2000], file=sys.stderr)
        return result.returncode
    if len(argv) != 2 or argv[0] != 'launch' or not argv[1].strip() or argv[1].startswith('-') or len(argv[1]) > 120:
        raise ValueError('Usage: commands.py launch "Application Name"')
    if sys.platform not in ('darwin', 'win32'):
        raise ValueError('App launch requires macOS or Windows')
    acquire()
    Path('.computer-used').touch()
    if sys.platform == 'win32':
        # Explicit executable/PATH names only; never interpret shell syntax.
        executable = shutil.which(argv[1])
        if not executable or Path(executable).suffix.lower() != '.exe':
            raise ValueError('Use a Windows .exe path or executable name, such as notepad.exe')
        process = subprocess.Popen([executable])
        print(json.dumps(dict(launched=True, app=argv[1], pid=process.pid, error=None)))
        return 0
    result = subprocess.run(['/usr/bin/open', '-a', argv[1]], capture_output=True, text=True, timeout=15)
    print(json.dumps(dict(launched=result.returncode == 0, app=argv[1], error=result.stderr.strip() or None)))
    return result.returncode


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(json.dumps({'error': str(error)}))
        sys.exit(1)
