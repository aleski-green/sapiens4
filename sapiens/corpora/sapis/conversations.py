"""Per-Sapi state, history, archives and prepared model context."""
from contextlib import contextmanager
import json
from pathlib import Path
import shlex
import sys
from uuid import uuid4

from sapiens.files import atomic_bytes, atomic_json, encode, file_lock, safe_child
from sapiens.paths import ROOT
from sapiens.prompts import prompt
from sapiens.runtime.contracts import Flow, Role
from sapiens.corpora.sapis.notes import Notes
from sapiens.validation import APIError


class Config:
    flows = {"chat": Flow(("conversation",)), "computer": Flow(("conversation",))}
    roles = {"conversation": Role(prompt("conversation").replace("{notes_wiki}", prompt("notes-wiki")))}


def computer_manifest(binary):
    launcher = ' '.join(shlex.quote(str(p)) for p in (sys.executable, ROOT / 'sapiens/computer/commands.py'))
    return prompt('computer-use', launcher=launcher, binary=shlex.quote(str(binary)))


class Conversation:
    def __init__(self, *, agid, root):
        self.agid = agid
        self.workspace = Path(root).resolve().parent / 'workspaces' / agid
        root = Path(root).resolve()
        self.root = safe_child(root / 'agents', agid)
        self.path = self.root / 'state.json'
        self.archive_root = root / 'corpora/archive'
        with file_lock(self.root / '.state.lock'):
            if not self.path.exists():
                self.write(dict(schema_version=3, agid=agid, revision=0,
                    turns=[], chat=[], events=[], event_sequence=0, last_output=None))
            saved = self.read()
            if saved['agid'] != agid:
                raise ValueError('Agent ID does not match saved state')
            if saved['schema_version'] < 3:
                version = saved['schema_version']
                backup = self.root / f'legacy-state-v{version}.json'
                if not backup.exists():
                    atomic_bytes(backup, self.path.read_bytes())
                turns = []
                for old in saved['jobs' if version == 1 else 'turns']:
                    if old['flow'] not in {'chat', 'computer'}:
                        continue
                    turn = {k: v for k, v in old.items() if k in {
                        'id','flow','status','created','error','warning'}}
                    turn['input'] = old['task' if version == 1 else 'input']
                    if turn['status'] == 'budget_blocked':
                        turn.update(status='interrupted', error='Former budget block removed; retry to continue')
                    turns.append(turn)
                saved = {k: saved[k] for k in ('agid','revision','chat','events','event_sequence','last_output')}
                saved.update(schema_version=3, turns=turns)
                for field in ('chat', 'events'):
                    for row in saved[field]:
                        if 'job' in row:
                            row['turn'] = row.pop('job')
                self.write(saved)

    def read(self):
        state = json.loads(self.path.read_bytes())
        if state.get("schema_version") not in (1, 2, 3):
            raise ValueError("Unsupported agent state schema")
        return state

    @contextmanager
    def transaction(self):
        with file_lock(self.root / ".state.lock"):
            state = self.read()
            yield state
            self.write(state)

    def write(self, state):
        state["revision"] += 1
        raw = encode(state)
        atomic_bytes(self.path, raw)

    @property
    def state(self):
        return self.read()

    @property
    def manifests(self):
        # Explicit allowlist keeps legacy scheduling/learning instructions inert.
        return {name: (self.root / 'manifests' / (name + '.md')).read_text()
                for name in ('identity','computer-use','host-control','host-facts','corpora-state')
                if (self.root / 'manifests' / (name + '.md')).is_file()}

    def set_manifest(self, name, text):
        if not name or '/' in name or '\\' in name:
            raise ValueError('Use a simple manifest name')
        atomic_bytes(safe_child(self.root / 'manifests', name + '.md'), text.encode())

    def transcript(self, turn_id):
        path = self.archive_path(f'runs/{turn_id}')
        return json.loads(path.read_bytes())['logs'] if path.exists() else []

    def result(self, turn_id):
        for message in self.state['chat']:
            if message.get('turn') == turn_id and message['role'] == 'agent':
                return message['content']
        path = self.archive_path(f'runs/{turn_id}')
        return json.loads(path.read_bytes())['output']

    def trim(self, state):
        for field in ('chat', 'events', 'turns'):
            rows = state[field]
            # A bounded chat window; full transcripts and UI history stay durable.
            settled = [r for r in rows if r.get('status') not in {'queued','running','output_pending'}]
            removed = settled[:-100]
            if removed:
                self.archive(f'{field}/{uuid4().hex}', removed)
                state[field] = [r for r in rows if r not in removed]

        for field in ('chat', 'events', 'turns'):
            removed = []
            for row in list(state[field]):
                if len(json.dumps(state, ensure_ascii=False).encode()) <= 800_000:
                    break
                if row.get('status') not in {'queued','running','output_pending'} and not (field == 'turns' and row == state[field][-1]):
                    state[field].remove(row)
                    removed.append(row)
            if removed:
                self.archive(f'{field}/{uuid4().hex}', removed)

    def context(self, snapshot, text, config):
        chat = [dict(m) for m in snapshot['chat'] if not (m.get('origin') or {}).get('group')][-20:]
        current = snapshot.get('current_turn')
        turns = {t['id']: t for t in snapshot.get('turns', [])}
        for message in chat:
            turn = turns.get(message.get('turn'), {})
            if (message.get('role') == 'user' and turn.get('batch_id', turn.get('id')) != current
                    and turn.get('status') in {'running', 'failed', 'interrupted'}):
                message['underPrevAgencyReview'] = True
        try:
            memo = Notes(self.workspace).read()['content']
        except (OSError, ValueError, APIError) as error:
            memo = dict(error=str(error))
        manifests = self.manifests
        blocks = dict(manifests={k: v for k, v in manifests.items() if k != 'corpora-state'},
                      staticContext=manifests.get('corpora-state', ''),
                      instantContext=dict(chat=chat, memo=memo),
                      inputs=snapshot.get('agency_batch', [dict(content=text)]))
        # TODO: context-specific SubMemo. Preserve the full Memo and all 20
        # messages now; snapshot maintenance belongs to a separate Agency.
        return dict(context=json.dumps(blocks, ensure_ascii=False), task=text, last='',
                    notes_example=str(ROOT / 'prompts/examples/jarvis-notes.html'))

    def archive_path(self, key):
        return safe_child(self.archive_root, f'{self.agid}/{key}.json')

    def archive(self, key, value):
        atomic_json(self.archive_path(key), value)
