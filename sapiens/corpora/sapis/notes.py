"""Model-managed HTML wiki; only identity and navigation enter call context."""
from html import escape
from html.parser import HTMLParser
import json
from pathlib import Path
import re

from sapiens.files import atomic_bytes, safe_child
from sapiens.validation import APIError


class Notes(HTMLParser):
    def __init__(self, workspace):
        super().__init__()
        self.workspace = Path(workspace).resolve()
        self.path = self.workspace / 'Notes.html'
        self.sections, self.capture, self.order = {}, None, []

    def handle_starttag(self, tag, attrs):
        if tag == 'section':
            self.order.append(dict(attrs).get('id'))
        if tag == 'section' and dict(attrs).get('id') in {'about', 'map', 'content'}:
            self.capture = dict(attrs)['id']
            self.sections[self.capture] = ''
        if self.capture in {'about', 'map'}:
            self.sections[self.capture] += self.get_starttag_text()

    def handle_endtag(self, tag):
        if self.capture in {'about', 'map'}:
            self.sections[self.capture] += f'</{tag}>'
        if tag == 'section':
            self.capture = None

    def handle_data(self, text):
        if self.capture in {'about', 'map'}:
            self.sections[self.capture] += escape(text)

    def ensure(self, name='', purpose=''):
        if self.path.exists() or self.path.is_symlink():
            return
        source = next((self.workspace / f'Notes.{ext}' for ext in ('yaml', 'md')
                       if (self.workspace / f'Notes.{ext}').exists() or (self.workspace / f'Notes.{ext}').is_symlink()), None)
        try:
            text = self.read(source)['content'] if source else ''
        except (APIError, OSError):
            return  # Preserve invalid legacy files; expose the error in context.
        if source and source.suffix == '.md':
            text = 'notes: ' + json.dumps(text, ensure_ascii=False).translate({
                c: f'\\u{c:04x}' for c in (*range(0x7f, 0xa0), 0x2028, 0x2029)})
        about = f'who: {json.dumps(name, ensure_ascii=False)}\npurpose: {json.dumps(purpose, ensure_ascii=False)}'
        chunks = [s for s in re.split(r'(?m)(?=^[a-zA-Z_][\w-]*:)', text) if s.strip()] or ['notes: []']
        titles = [re.match(r'[\w-]+(?=:)', s)[0] if re.match(r'[\w-]+(?=:)', s) else 'remembered' for s in chunks]
        links = ''.join(f'<a href="#entry-{i}">{escape(title)}</a> — saved {escape(title)}<br>' for i, title in enumerate(titles))
        snippets = ''.join(f'<article id="entry-{i}"><pre><code class="language-yaml">{escape(s)}</code></pre></article>\n' for i, s in enumerate(chunks))
        document = (f'<section id="about"><pre><code class="language-yaml">{escape(about)}</code></pre></section>\n'
                    f'<section id="map"><nav>{links}</nav></section>\n<section id="content">{snippets}</section>\n')
        atomic_bytes(self.path, document.encode())

    def validate(self, path):
        if path.is_symlink() or path.resolve().parent != self.workspace or (path.exists() and not path.is_file()):
            raise APIError(409, f'{path.name} must be a regular file inside this Sapi workspace')

    def metadata(self):
        try:
            self.validate(self.path)
            stat = self.path.stat() if self.path.exists() else None
            return dict(path=str(self.path), revision=f'{stat.st_mtime_ns}:{stat.st_size}' if stat else 'missing')
        except APIError as error:
            return dict(path=str(self.path), error=str(error), revision='invalid')

    def read(self, path=None):
        path = path or self.path
        self.validate(path)
        try:
            with path.open(encoding='utf-8', newline='') as stream:
                text = stream.read()
        except FileNotFoundError:
            raise APIError(409, 'Notes.html is missing; check the original Notes file before recreating it.') from None
        except UnicodeError:
            raise APIError(409, f'{path.name} must contain UTF-8 text') from None
        return dict(path=str(path), content=text)

    def context(self):
        try:
            self.sections, self.capture, self.order = {}, None, []
            self.reset()
            self.feed(self.read()['content'])
            if self.order != ['about', 'map', 'content']:
                raise APIError(409, 'Notes.html requires sections with ids about, map, and content.')
            return dict(path=str(self.path), **{k: v if len(v) <= 12000 else None
                        for k, v in self.sections.items() if k != 'content'})
        except (APIError, OSError) as error:
            return dict(path=str(self.path), error=str(error))

    def image(self, name):
        path = safe_child(self.workspace, name)
        mime = {'.png':'image/png', '.jpg':'image/jpeg', '.jpeg':'image/jpeg', '.gif':'image/gif', '.webp':'image/webp'}
        if path.suffix.lower() not in mime or not path.is_file() or path.stat().st_size > 10_000_000:
            raise APIError(404, 'Notes image not found or too large')
        return path.read_bytes(), mime[path.suffix.lower()]
