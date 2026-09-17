"""Agent-owned artifacts and workspace tabs, shared with the browser UI."""
from html import escape
from pathlib import Path
import re
from urllib.parse import quote, urlsplit
from uuid import uuid4

from agentpy.storage import atomic_bytes


class Workspace:
    def __init__(self, service):
        self.service = service

    def root(self, agent):
        return self.service.root / 'workspaces' / agent.agid

    def path(self, agent, name):
        from .service import APIError
        name = self.service.artifacts.resolve(agent.agid, name)
        if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\.(md|html|txt|json)', name):
            raise APIError(400, 'Artifact name must be a filename ending in .md, .html, .txt or .json')
        root = self.root(agent) / 'artifacts'
        if root.is_symlink() or (root / name).is_symlink():
            raise APIError(400, 'Artifact paths must not be symlinks')
        return root / name

    def summary(self, agent):
        prefs = self.service.store.read_preferences()
        ws = prefs.get('workspaces', {}).get(agent.agid, {})
        artifacts = [{k: r[k] for k in ('filename','reference','tag','title')}
                     for r in self.service.artifacts.catalog() if r['owner'] == agent.agid]
        return dict(active_tab=ws.get('activeTab'),
            tabs=[{k: t[k] for k in ('id', 'title', 'type', 'url', 'artifact') if k in t}
                  for t in ws.get('tabs', [])], artifacts=[dict(r,name=r['filename']) for r in artifacts])

    def save(self, agent, data):
        from .service import APIError
        path = self.path(agent, data.get('name'))
        if ('content' in data) == ('path' in data):
            raise APIError(400, 'Supply either content or a relative path to a UTF-8 file in your workspace')
        if 'path' in data:
            value = data['path']
            if not isinstance(value, str) or Path(value).is_absolute():
                raise APIError(400, 'Source path must be relative to your workspace')
            source = (self.root(agent) / value).resolve()
            if not source.is_relative_to(self.root(agent).resolve()) or not source.is_file():
                raise APIError(400, 'Source must be a file inside your workspace')
            if source.stat().st_size > 1_000_000:
                raise APIError(413, 'Artifact exceeds 1 MB')
            try:
                content = source.read_text(encoding='utf-8')
            except UnicodeError:
                raise APIError(400, 'Artifact must be UTF-8 text') from None
        else:
            content = data['content']
        if not isinstance(content, str) or not content.strip() or len(content.encode()) > 1_000_000:
            raise APIError(400, 'Artifact must be nonempty UTF-8 text, at most 1 MB')
        if 'open' in data and type(data['open']) is not bool:
            raise APIError(400, 'open must be boolean')
        title = data.get('title', path.stem)
        if not isinstance(title, str) or not title.strip() or len(title) > 100:
            raise APIError(400, 'title must be nonempty text, at most 100 characters')
        path.parent.mkdir(parents=True, exist_ok=True)
        atomic_bytes(path, content.encode())
        identity = self.service.artifacts.ensure(agent.agid, path.name, title)
        result = dict(name=path.name, reference=identity['reference'], tag=identity['tag'], path=str(path), bytes=path.stat().st_size,
                      url=f'/api/agents/{agent.agid}/artifacts/{quote(path.name)}')
        if data.get('open', True):
            result['tab'] = self.open(agent, dict(artifact=path.name, title=title))
        else:
            # Refresh any already-open view of this artifact without stealing focus.
            prefs = self.service.store.read_preferences()
            ws = prefs.get('workspaces', {}).get(agent.agid, {})
            for tab in ws.get('tabs', []):
                if tab.get('artifact') == path.name:
                    tab['html'] = self.preview(path)
            self.persist(prefs)
        return result

    def read(self, agent, name):
        from .service import APIError
        path = self.path(agent, name)
        if not path.is_file():
            raise APIError(404, 'Artifact not found')
        text = path.read_text()
        return dict(name=path.name, reference=self.service.artifacts.ensure(agent.agid,path.name)['reference'], content=text[:64000], truncated=len(text) > 64000)

    def persist(self, prefs):
        prefs['workspace_revision'] = prefs.get('workspace_revision', 0) + 1
        self.service.store.preferences(prefs)

    def open(self, agent, data):
        from .service import APIError
        prefs = self.service.store.read_preferences()
        ws = prefs.setdefault('workspaces', {}).setdefault(agent.agid, {'tabs': []})
        tabs = ws['tabs']
        tab = next((t for t in tabs if t['id'] == data.get('id')), None)
        if 'id' in data and tab is None:
            raise APIError(404, 'Unknown workspace tab')
        if ('artifact' in data) == ('url' in data):
            raise APIError(400, 'Supply either artifact or an HTTP(S) URL')
        if 'artifact' in data:
            path = self.path(agent, data['artifact'])
            if not path.is_file():
                raise APIError(404, 'Save the artifact before opening it')
            tab = tab or next((t for t in tabs if t.get('artifact') == path.name), None)
            value = dict(type='html', artifact=path.name, html=self.preview(path))
            title = data.get('title', (tab or {}).get('title', path.stem))
        else:
            url = data['url']
            if not isinstance(url, str) or len(url) > 4000:
                raise APIError(400, 'Invalid URL')
            parsed = urlsplit(url)
            if parsed.scheme not in {'http', 'https'} or not parsed.netloc or parsed.username or parsed.password:
                raise APIError(400, 'Workspace URLs must be HTTP(S) without credentials')
            value = dict(type='custom', url=url)
            title = data.get('title', parsed.hostname)
        if not isinstance(title, str) or not title.strip() or len(title) > 100:
            raise APIError(400, 'title must be nonempty text, at most 100 characters')
        value.update(id=tab['id'] if tab else 'tab-' + uuid4().hex, title=title)
        if tab:
            tabs[tabs.index(tab)] = value
        else:
            if len(tabs) >= 50:
                raise APIError(400, 'Close a workspace tab before adding more')
            tabs.append(value)
        ws['activeTab'] = value['id']
        self.persist(prefs)
        return {k: v for k, v in value.items() if k != 'html'}

    def close(self, agent, tab_id):
        from .service import APIError
        prefs = self.service.store.read_preferences()
        ws = prefs.get('workspaces', {}).get(agent.agid, {})
        tabs = ws.get('tabs', [])
        if not any(t['id'] == tab_id for t in tabs):
            raise APIError(404, 'Unknown workspace tab')
        ws['tabs'] = [t for t in tabs if t['id'] != tab_id]
        if ws.get('activeTab') == tab_id:
            ws['activeTab'] = next((t['id'] for t in ws['tabs']), None)
        self.persist(prefs)
        return {'closed': tab_id}

    @staticmethod
    def inline_markdown(text):
        pattern = re.compile(r'\[([^\]\n]+)\]\((?:<([^>\n]+)>|((?:[^()\s]|\([^()\s]*\))+))\)|`([^`\n]+)`|\*\*([^*\n]+)\*\*')
        result, cursor = [], 0
        for match in pattern.finditer(text):
            result.append(escape(text[cursor:match.start()]))
            label, angle, bare, code, bold = match.groups()
            if label is not None:
                url = angle or bare
                try:
                    parsed = urlsplit(url)
                    safe = parsed.scheme in {'http', 'https'} and bool(parsed.netloc)
                except ValueError:
                    safe = False
                if safe:
                    result.append(f'<a href="{escape(url, quote=True)}" target="_blank" rel="noopener noreferrer">{escape(label)} ↗</a>')
                else:
                    result.append(escape(label))
            elif code is not None:
                result.append('<code>' + escape(code) + '</code>')
            else:
                result.append('<strong>' + escape(bold) + '</strong>')
            cursor = match.end()
        return ''.join(result) + escape(text[cursor:])

    @staticmethod
    def preview(path):
        content = path.read_text()
        # HTML dashboards execute in the existing opaque-origin sandbox. Disable
        # network access: a generated document cannot call the host's control API.
        policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; form-action 'none'; base-uri 'none'"
        if path.suffix == '.html':
            return f'<meta http-equiv="Content-Security-Policy" content="{policy}">' + content
        body = []
        code = False
        for line in content.splitlines():
            if path.suffix == '.md' and line.startswith('```'):
                body.append('</pre>' if code else '<pre>')
                code = not code
            elif code:
                body.append(escape(line) + '\n')
            elif path.suffix == '.md' and (match := re.match(r'^(#{1,6}) (.*)$', line)):
                level = len(match[1])
                body.append(f'<h{level}>{Workspace.inline_markdown(match[2])}</h{level}>')
            else:
                body.append(f'<div class="line">{(Workspace.inline_markdown(line) if path.suffix == ".md" else escape(line)) or "<br>"}</div>')
        if code:
            body.append('</pre>')
        return f'''<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="{policy}">
<title>{escape(path.name)}</title><style>body{{max-width:850px;margin:32px auto;padding:0 24px;font:16px/1.6 system-ui;color:#202030;background:#faf9f6}}.line{{white-space:pre-wrap;overflow-wrap:anywhere}}pre{{white-space:pre-wrap;background:#eeebf3;padding:16px}}h1,h2,h3{{line-height:1.2}}a{{color:#7435b8;overflow-wrap:anywhere}}code{{background:#eeebf3;padding:2px 4px}}</style>''' + '\n'.join(body)
