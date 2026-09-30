"""CORPORA avatars, terminal-safe text, machine envelopes and waiting indicators."""
from html.parser import HTMLParser
import json
import os
import re
import shutil
import sys
import textwrap
import time

def clean(value):
    text = re.sub(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', '', str(value if value is not None else ''))
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    return ''.join(c for c in text if c in '\n\t' or (ord(c) >= 32 and not 127 <= ord(c) <= 159))

class NoteText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts, self.hidden = [], 0
    def tag(self, tag, opening):
        if tag in {'script', 'style'}:
            self.hidden = max(0, self.hidden + (1 if opening else -1))
        if tag in {'p', 'article', 'section', 'pre', 'li', 'h1', 'h2', 'h3'} or tag == 'br' and opening:
            self.parts.append('\n')
    def handle_starttag(self, tag, attrs):
        self.tag(tag, True)
    def handle_endtag(self, tag):
        self.tag(tag, False)
    def handle_data(self, data):
        if not self.hidden: self.parts.append(data)

def note_text(source):
    parser = NoteText()
    parser.feed(source)
    return re.sub(r'\n{3,}', '\n\n', ''.join(parser.parts)).strip()

class Renderer:
    def __init__(self, format='human', plain=False, animation=True, stdout=None, stderr=None):
        self.out, self.err = stdout or sys.stdout, stderr or sys.stderr
        self.plain = plain or (getattr(self.out, 'encoding', None) or 'utf-8').lower() in {'ascii', 'ansi_x3.4-1968'}
        self.format, self.sequence = format, 0
        self.animate = animation and not self.plain and self.err.isatty() and format == 'human' and not os.environ.get('NO_COLOR')
    def avatar(self, agent=None):
        face = clean((agent or {}).get('face', '')).replace('\n', '').replace('\t', '')
        return f'({face}) ' if face and not self.plain else ''
    def text(self, value=''):
        value = clean(value)
        value = value.encode('ascii', 'backslashreplace').decode() if self.plain else value
        for line in value.split('\n'):
            print(textwrap.fill(line, width=max(20, shutil.get_terminal_size((90, 24)).columns - 2),
                                replace_whitespace=False, drop_whitespace=False), file=self.out)
        self.out.flush()
    def sapis(self, rows):
        return '\n\n'.join(self.avatar(a) + a['name'] + (' [Chief]' if a['chief'] else '') + ' | ' + a['state'] +
            '\n  ' + a['id'] + ' | ' + a['role'] + ('\n' + json.dumps(a['details'], ensure_ascii=False, indent=2) if 'details' in a else '') for a in rows) or 'No Sapis.'
    def tasks(self, rows, identities):
        return '\n\n'.join(self.avatar(identities.get(t['owner'])) + t['state'] + ' | ' + identities.get(t['owner'], {}).get('name', t['owner']) +
                           '\n  ' + t['title'] + '\n  ' + t['id'] for t in rows) or 'No tasks in this view.'
    def emit(self, data=None, human='', error=None, event='snapshot'):
        self.clear()
        if self.format == 'human':
            self.text('Error: ' + str(error) + ('\nNext: ' + error.hint if error.hint else '') if error else human)
        elif self.format == 'yaml':
            print(clean(str(error)) if error else data['body'], end='' if not error and data['body'].endswith('\n') else '\n', file=self.err if error else self.out)
        else:
            record = dict(schema_version=1, data=data, error=dict(code=error.code, message=str(error), hint=error.hint) if error else None)
            if self.format == 'json': record['ok'] = error is None
            else:
                self.sequence += 1
                record.update(seq=self.sequence, observed_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), event=event)
            print(json.dumps(record), file=self.out, flush=True)
    def tick(self, state, elapsed, frame, agent=None):
        self.clear(f'{self.avatar(agent)}{state} {(".", "..", "...")[frame % 3]}  waiting {elapsed:.0f}s | Ctrl-C detaches')
    def clear(self, message=''):
        if self.animate:
            self.err.write('\r\x1b[2K' + message[:max(10, shutil.get_terminal_size((90, 24)).columns - 2)])
            self.err.flush()
