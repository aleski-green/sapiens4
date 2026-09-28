"""Per-Sapi browser tabs and bookmarks. Documents remain ordinary files."""
from pathlib import Path
from urllib.parse import urlsplit, unquote
from uuid import uuid4

from .sdk import atomic_bytes
from .validation import APIError


class Workspace:
    def __init__(self, service):
        self.service = service
        self.migrate()

    def root(self, agent):
        return self.service.root / 'workspaces' / agent.agid

    def migrate(self):
        prefs = self.service.store.read_preferences()
        if prefs.get('browser_version') == 1:
            return
        for owner, ws in prefs.get('workspaces', {}).items():
            folder = self.service.root / 'workspaces' / owner
            for tab in ws.get('tabs', []):
                if tab.get('artifact'):
                    tab['path'] = str(folder / 'artifacts' / tab['artifact'])
                elif tab.get('type') == 'html':
                    # Preserve inline documents once, without keeping HTML in preferences.
                    path = folder / ('saved-tab-' + uuid4().hex + '.html')
                    atomic_bytes(path, tab.get('html', '').encode())
                    tab['path'] = str(path)
                if tab.get('path'):
                    tab['url'] = Path(tab['path']).as_uri()
                tab['url'] = tab.get('url') or 'about:blank'
                for key in ('type', 'artifact', 'html'):
                    tab.pop(key, None)
                tab.update(zoom=1, command={'seq': uuid4().hex, 'action': 'navigate'})
            ws.setdefault('bookmarks', [])
        prefs['browser_version'] = 1
        self.persist(prefs)

    def summary(self, agent):
        ws = self.service.store.read_preferences().get('workspaces', {}).get(agent.agid, {})
        return dict(active_tab=ws.get('activeTab'), tabs=ws.get('tabs', []), bookmarks=ws.get('bookmarks', []))

    def persist(self, prefs):
        prefs['workspace_revision'] = prefs.get('workspace_revision', 0) + 1
        self.service.store.preferences(prefs)

    def destination(self, agent, data, *, check_file=True):
        if ('path' in data) == ('url' in data):
            raise APIError(400, 'Supply a file path or a URL')
        value = data.get('path', data.get('url'))
        if not isinstance(value, str) or not value.strip() or len(value) > 8192:
            raise APIError(400, 'Invalid file path or URL')
        try:
            parsed = urlsplit(value)
            if 'path' in data or parsed.scheme == 'file':
                if 'path' not in data and parsed.netloc not in ('', 'localhost'):
                    raise ValueError()
                path = Path(value if 'path' in data else unquote(parsed.path)).expanduser()
                if not path.is_absolute():
                    path = self.root(agent) / path
                path = path.resolve()
                if check_file and not path.is_file():
                    raise APIError(404, 'File not found')
                return dict(url=path.as_uri(), path=str(path), title=path.name)
            if value == 'about:blank':
                return dict(url=value, title='New tab')
            if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password:
                raise ValueError()
            return dict(url=value, title=parsed.hostname)
        except (ValueError, OSError):
            raise APIError(400, 'Use an HTTP(S) URL or a local file path') from None

    def control(self, agent, action, data):
        prefs = self.service.store.read_preferences()
        ws = prefs.setdefault('workspaces', {}).setdefault(agent.agid, dict(tabs=[], bookmarks=[]))
        tabs = ws['tabs']
        tab = next((t for t in tabs if t['id'] == data.get('id', ws.get('activeTab'))), None)
        if action == 'open':
            value = self.destination(agent, data)
            if 'id' in data and tab is None:
                raise APIError(404, 'Unknown browser tab')
            if 'id' not in data:
                tab = dict(id='tab-' + uuid4().hex, zoom=1)
                tabs.append(tab)
            tab.pop('path', None)
            tab.update(value)
            tab.update(error='', loading=True, can_back=False, can_forward=False)
            tab['command'] = dict(seq=uuid4().hex, action='navigate')
            ws['activeTab'] = tab['id']
        elif action == 'unbookmark':
            ws['bookmarks'] = [b for b in ws.get('bookmarks', []) if b['id'] != data.get('id')]
        else:
            if tab is None:
                raise APIError(404, 'Unknown browser tab')
            if action == 'close':
                tabs.remove(tab)
                if ws.get('activeTab') == tab['id']:
                    ws['activeTab'] = tabs[-1]['id'] if tabs else None
            elif action == 'focus':
                ws['activeTab'] = tab['id']
            elif action == 'zoom':
                value = data.get('factor')
                if type(value) not in (float, int) or not .25 <= value <= 5:
                    raise APIError(400, 'Zoom factor must be between 0.25 and 5')
                tab['zoom'] = value
            elif action == 'bookmark':
                bookmarks = ws.setdefault('bookmarks', [])
                if not any(b['url'] == tab['url'] for b in bookmarks):
                    bookmarks.append(dict(id=uuid4().hex, **{k: tab[k] for k in ('url', 'title', 'path') if k in tab}))
            elif action in ('reload', 'back', 'forward'):
                tab['command'] = dict(seq=uuid4().hex, action=action)
            else:
                raise APIError(400, 'Unknown browser action')
        self.persist(prefs)
        return self.summary(agent)

    def observed(self, agent, data):
        """Accept native navigation metadata only for the current command/tab."""
        prefs = self.service.store.read_preferences()
        tabs = prefs.get('workspaces', {}).get(agent.agid, {}).get('tabs', [])
        tab = next((t for t in tabs if t['id'] == data.get('id')), None)
        if tab is None or data.get('seq') != tab.get('command', {}).get('seq'):
            return {'saved': False}
        value = self.destination(agent, {'url': data.get('url')}, check_file=False)
        title = data.get('title')
        if isinstance(title, str) and title.strip():
            value['title'] = title[:500]
        value.update(can_back=data.get('can_back') is True, can_forward=data.get('can_forward') is True,
                     loading=data.get('loading') is True, error=str(data.get('error') or '')[:1000])
        if any(tab.get(k) != v for k, v in value.items()) or ('path' in tab and 'path' not in value):
            tab.pop('path', None)
            tab.update(value)
            self.persist(prefs)
        return {'saved': True}
