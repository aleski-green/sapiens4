"""A Sapi's own plain Markdown file; no learning or background processing."""
from pathlib import Path

from sapiens.validation import APIError


class Notes:
    preview_chars = 12000
    display_chars = 64000

    def __init__(self, workspace):
        self.workspace = Path(workspace).resolve()
        self.path = self.workspace / 'Notes.md'

    def ensure(self):
        self.workspace.mkdir(parents=True, exist_ok=True)
        try:
            with self.path.open('x', encoding='utf-8') as stream:
                stream.write('')
        except FileExistsError:
            pass

    def validate(self):
        if self.path.is_symlink() or self.path.resolve().parent != self.workspace:
            raise APIError(409, 'Notes.md must be a regular file inside this Sapi workspace')
        if self.path.exists() and not self.path.is_file():
            raise APIError(409, 'Notes.md must be a regular file')

    def metadata(self):
        try:
            self.validate()
            stat = self.path.stat() if self.path.exists() else None
            return dict(path=str(self.path), revision=f'{stat.st_mtime_ns}:{stat.st_size}' if stat else 'missing')
        except APIError as error:
            return dict(path=str(self.path), error=str(error), revision='invalid')

    def read(self, limit=None):
        self.validate()
        try:
            with self.path.open(encoding='utf-8') as stream:
                text = stream.read((limit or self.display_chars) + 1)
        except FileNotFoundError:
            text = ''
        except UnicodeError:
            raise APIError(409, 'Notes.md must contain UTF-8 text') from None
        size = limit or self.display_chars
        return dict(path=str(self.path), content=text[:size], truncated=len(text) > size)

    def context(self):
        try:
            return self.read(self.preview_chars)
        except APIError as error:
            return dict(path=str(self.path), error=str(error))
