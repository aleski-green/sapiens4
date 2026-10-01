"""CORPORA avatars, terminal-safe text, machine envelopes and waiting indicators."""
from html.parser import HTMLParser
import json, os, re, shutil, sys, textwrap, time
try:
    from prompt_toolkit import PromptSession; from prompt_toolkit.key_binding import KeyBindings
    from prompt_toolkit.key_binding.bindings.completion import display_completions_like_readline
    from prompt_toolkit.completion import Completer, Completion
    from prompt_toolkit.formatted_text import ANSI
    from prompt_toolkit.history import InMemoryHistory
    from prompt_toolkit.output import ColorDepth
except ImportError: PromptSession = None
def clean(value):
    text = re.sub(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', '', str(value if value is not None else ''))
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    return ''.join(c for c in text if c in '\n\t' or (ord(c) >= 32 and not 127 <= ord(c) <= 159))
class NoteText(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts, self.hidden = [], 0
    def tag(self, tag, opening):
        if tag in {'script', 'style'}: self.hidden = max(0, self.hidden + (1 if opening else -1))
        if tag in {'p', 'article', 'section', 'pre', 'li', 'h1', 'h2', 'h3'} or tag == 'br' and opening: self.parts.append('\n')
    def handle_starttag(self, tag, attrs): self.tag(tag, True)
    def handle_endtag(self, tag): self.tag(tag, False)
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
        self.styles = {word: code for code, words in [('1;36', 'ABOUT STATS'), ('32', 'online ready done Completed'),
            ('33', 'queued Queued running Running WaitingForAdmin'), ('31', 'failed Failed Interrupted Unresolved Error:')] for word in words.split()}
        self.styles['sapiens4'] = '38;2;255;90;165'  # Dark-theme wordmark pink, #ff5aa5.
        self.animate = animation and not self.plain and self.err.isatty() and format == 'human' and 'NO_COLOR' not in os.environ and os.environ.get('TERM') != 'dumb'
    def avatar(self, agent=None):
        face = clean((agent or {}).get('face', '')).replace('\n', '').replace('\t', '')
        color = str((agent or {}).get('color') or '')
        if face and re.fullmatch(r'#[0-9a-fA-F]{6}', color):
            self.styles[f'({face})'] = '48;2;' + ';'.join(str(int(color[i:i+2], 16)) for i in (1, 3, 5)) + ';38;2;39;33;55'
        return f'({face}) ' if face and not self.plain else ''
    def paint(self, value, stream=None, styles=None):
        if self.plain or self.format != 'human' or 'NO_COLOR' in os.environ or os.environ.get('TERM') == 'dumb' or not (stream or self.out).isatty(): return value
        styles = self.styles if styles is None else styles
        pattern = '|'.join(re.escape(key) for key in sorted(styles, key=len, reverse=True))
        return re.sub(r'(?<!\w)(' + pattern + r')(?!\w)', lambda m: f'\x1b[{styles[m[0]]}m{m[0]}\x1b[0m', value)
    def text(self, value=''):
        value = clean(value)
        value = value.encode('ascii', 'backslashreplace').decode() if self.plain else value
        for line in value.split('\n'):
            print(self.paint(textwrap.fill(line, width=max(20, shutil.get_terminal_size((90, 24)).columns - 2),
                                replace_whitespace=False, drop_whitespace=False)), file=self.out)
        self.out.flush()
    def prompt(self, agent=None):
        label = clean(agent['name']).replace('\n', '').replace('\t', '') if agent else 'corpora'; label = label.encode('ascii', 'backslashreplace').decode() if self.plain else label
        color = lambda text, rgb: self.paint(text, styles={text: '38;2;' + rgb})
        return ('' if agent else color('>> ', '185;176;189')) + color('sapiens4', '255;90;165') + color('::' if self.plain else ' ⌘ ', '185;176;189') + ('@' + label if agent else color(label, '217;233;184')) + color(' > ', '185;176;189')
    def read(self, agent, history, complete):
        prompt = self.prompt(agent)
        if not sys.stdin.isatty(): return input(prompt)
        class Names(Completer):
            def get_completions(self, document, event):
                prefix = document.text_before_cursor
                for value in complete(prefix): yield Completion(value, -len(prefix), display=value.split('@', 1)[-1])
        keys = KeyBindings(); keys.add('tab')(display_completions_like_readline)
        return PromptSession(history=InMemoryHistory(history), completer=Names(), key_bindings=keys, complete_while_typing=False,
                             color_depth=ColorDepth.TRUE_COLOR if '\x1b[' in prompt else ColorDepth.MONOCHROME).prompt(ANSI(prompt))
    def sapis(self, rows):
        for a in rows: self.styles[clean(a['id'])] = '38;2;167;189;182'
        title = lambda a: ('*' if a['chief'] else '') + self.avatar(a) + a['name'] + (' | ' if self.plain else ' · ') + a['role']
        if rows and 'details' in rows[0]:
            return '\n\n'.join(title(a) + '\nid: ' + a['id'] + '\nworkspace: ' + a['workspace'] + '\nStatus: ' + a['state'] for a in rows)
        rows = sorted(rows, key=lambda a: not a['chief'])
        return 'corpora' + ''.join('\n' + (('`-- ' if i == len(rows) - 1 else '|-- ') if self.plain else ('└── ' if i == len(rows) - 1 else '├── ')) + title(a) + (' [retired]' if a.get('retired') else '') for i, a in enumerate(rows))
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
            self.err.write('\r\x1b[2K' + self.paint(clean(message)[:max(10, shutil.get_terminal_size((90, 24)).columns - 2)], self.err))
            self.err.flush()
