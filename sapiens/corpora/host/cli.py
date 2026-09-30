"""Keyboard-first CORPORA commands, prompt and bounded observation."""
import argparse
from functools import lru_cache
import math
import shlex
import sys
import time
from urllib.parse import quote
from sapiens.corpora.host.cli_render import Renderer, clean, note_text
from sapiens.corpora.host.cli_transport import Client, ClientError, require
try:
    import readline
except ImportError:
    readline = None

# Command: positional argument, command-specific options, help description.
COMMANDS = {
    'status': ('', 'watch', 'Live status; --watch observes changes'),
    'doctor': ('', '', 'Check host and reported capabilities'),
    'sapi list': ('', 'all', 'List Sapis; --all includes retired'),
    'sapi show': ('id', '', 'Show identity and workspace'),
    'task list': ('', 'tab', 'List upcoming, past or all tasks'),
    'task show': ('id', '', 'Show YAML body and result'),
    'history': ('', 'limit', 'Read recent inputs and replies'),
    'memo show': ('', '', 'Read Notes as Memo'),
    'chat': ('message', 'wait workload', 'Submit once; --wait observes; --workload binds a clarification'),
    'conversation watch': ('id', '', 'Observe a turn and its delegated workload'),
    'conversation retry': ('id', '', 'Explicitly retry an eligible turn'),
    'conversation cancel': ('id', '', 'Cancel an eligible turn'),
    'shell': ('', '', 'Open the interactive prompt'), 'help': ('', '', 'Show commands and options')}
GLOBALS = dict(url=None, format='human', plain=False, no_animation=False, timeout=120, sapi='chief')
DEFAULTS = dict(GLOBALS, watch=False, all=False, tab='all', limit=5, wait=False, workload=None)
PAST = {'Completed', 'Unresolved', 'Failed', 'Interrupted', 'Cancelled'}
EXIT = dict(done=0, completed=0, waitingforadmin=5, failed=1, interrupted=1, cancelled=1, unresolved=1)

class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ClientError('USAGE', message, 2, 'Run sapiens4 help.')

@lru_cache(maxsize=1)
def parser():
    result = Parser(prog='sapiens4', add_help=False, allow_abbrev=False, argument_default=argparse.SUPPRESS)
    for name, settings in {
        'url': {}, 'sapi': {}, 'format': dict(choices=['human', 'json', 'jsonl', 'yaml']),
        'timeout': dict(type=float), 'limit': dict(type=int), 'tab': dict(choices=['upcoming', 'past', 'all']),
        'workload': {}, **{key: dict(action='store_true') for key in ['watch', 'all', 'wait', 'plain', 'no-animation']}
    }.items():
        result.add_argument('--' + name, **settings)
    return result

def parse(argv, selected='chief', defaults=None):
    given, words = parser().parse_known_args(argv)
    protected = '--' in words
    if protected: words.remove('--')
    words = words or ['status']
    words = {'sapis': ['sapi', 'list'], 'tasks': ['task', 'list'], '--help': ['help'], '-h': ['help']}.get(words[0], [words[0]]) + words[1:]
    key = ' '.join(words[:2]) if ' '.join(words[:2]) in COMMANDS else words[0]
    position, allowed, _ = COMMANDS.get(key, ('', '', ''))
    values = words[len(key.split()):]
    require(key in COMMANDS and len(values) == bool(position) and (protected or not any(v.startswith('-') and not v[1:].replace('.', '', 1).isdigit() for v in values))
            and not (set(vars(given)) - set(GLOBALS) - set(allowed.split())),
            'Unknown command, argument or option.', hint='Run sapiens4 help.')
    options = argparse.Namespace(**{**DEFAULTS, **(defaults or {}), 'sapi': selected, **vars(given), 'command': key})
    if position: setattr(options, position, values[0])
    require(math.isfinite(options.timeout) and options.timeout > 0 and options.limit > 0, '--timeout must be finite and positive; --limit must be positive.')
    watching = key == 'conversation watch' or key == 'status' and options.watch
    require((options.format != 'jsonl' or watching) and (options.format != 'yaml' or key == 'task show'), 'JSONL requires a watch; YAML requires task show.')
    return options

def status_data(state):
    return dict(provider=state.get('provider'), chief=state.get('main_agent_id'),
        active_sapis=sum(not a.get('retired') for a in state['agents']), retired_sapis=sum(bool(a.get('retired')) for a in state['agents']),
        running=sum(t['status'] == 'running' for t in state['turns']), queued=sum(t['status'] == 'queued' for t in state['turns']),
        waiting=[w for w in state.get('workloads', []) if w['state'] == 'WaitingForAdmin'])

def status_text(data, url):
    return (f"CORPORA | online\n{url}\n{data['active_sapis']} active Sapis | {data['retired_sapis']} retired | "
            f"{data['running']} running | {data['queued']} queued\nProvider: {data['provider']}" + ''.join(
                f"\nNeeds your answer: {w['id']}\n{w.get('output') or ''}\nchat \"answer\" --sapi chief --workload {w['id']}" for w in data['waiting']))

def conversation_data(state, agent, turn_id):
    turn = next((t for t in state['turns'] if t['id'] == turn_id and t['agent'] == agent['id']), None)
    require(turn is not None, 'Conversation not found for this Sapi.', 'NOT_FOUND')
    work = next((w for w in state.get('workloads', []) if w.get('origin', {}).get('call') == turn_id or w.get('callId') == turn_id), None)
    source = work or turn
    return dict(id=turn_id, agent=agent['id'], state=source.get('state', source.get('status')),
                workload=work['id'] if work else None, output=source.get('output'), error=source.get('error'))

def observe(client, renderer, options, agent=None, turn_id=None, initial_state=None):
    started, previous, data, frame = time.monotonic(), None, None, 0
    deadline = started + options.timeout
    try:
        while time.monotonic() < deadline:
            client.timeout = min(5, max(.01, deadline - time.monotonic()))
            state = initial_state if initial_state is not None else client.state()
            initial_state = None
            data = conversation_data(state, agent, turn_id) if turn_id else status_data(state)
            status = data['state'] if turn_id else ('running' if data['running'] else 'ready')
            work = next((w for w in state.get('workloads', []) if w['id'] == data.get('workload')), {})
            owner = next((a for a in state['agents'] if a['id'] == work.get('owner', (agent or {}).get('id'))), None)
            code = EXIT.get(status.lower()) if turn_id else None
            error = ClientError('OPERATION_FAILED', data.get('error') or status) if code == 1 else None
            if data != previous and (renderer.format != 'json' or code is not None):
                human = renderer.avatar(owner) + status + ' | ' + turn_id + '\n' + (data.get('output') or '') if turn_id else status_text(data, client.url)
                if code == 5:
                    human += '\nReply: chat "answer" --sapi chief --workload ' + data['workload']
                renderer.emit(data, human, error, 'snapshot' if previous is None else 'state_changed')
            previous = data
            if code is not None: return code
            for _ in range(4):
                renderer.tick(status, time.monotonic() - started, frame, owner)
                frame += 1
                time.sleep(max(0, min(.25, deadline - time.monotonic())))
        raise ClientError('TIMEOUT', 'Observation deadline reached; server work continues.', 4,
                          'Use conversation watch with the same ID to reconnect.' if turn_id else 'Run status again.')
    except (KeyboardInterrupt, ClientError) as error:
        error = ClientError('DETACHED', 'Observer detached; server work continues.', 130) if isinstance(error, KeyboardInterrupt) else error
        if data is not None and error.code not in {'TIMEOUT', 'DETACHED'}:
            error.hint = 'Last observation is stale. Reconnect to check current state.'
        renderer.emit(data, error=error, event={'TIMEOUT': 'timeout', 'DETACHED': 'detached'}.get(error.code, 'error'))
        return error.exit_code
    finally:
        renderer.clear()

def dispatch(options, client, renderer):
    key = options.command
    if key == 'help':
        help_text = 'Sapiens4 / CORPORA\n\n' + '\n'.join(f'  {name} {"<" + arg + ">" if arg else ""}  {description}' for name, (arg, _, description) in COMMANDS.items())
        help_text += '\n\n' + parser().format_help() + '\nPrompt: use <Sapi>, sapis, tasks, exit. Arrow keys recall non-chat commands.\nCtrl-C detaches; server work continues. Only Chief creates Sapis.'
        renderer.emit({'help': help_text}, help_text)
        return 0
    if key == 'shell': return shell(options, client, renderer)
    if key == 'status' and options.watch: return observe(client, renderer, options)
    state = client.state()
    identities = {a['id']: a for a in state['agents']}
    if key == 'status':
        data = status_data(state)
        human = status_text(data, client.url)
    elif key == 'doctor':
        data = dict(host=client.request('/api/health'), state='readable', provider=state.get('provider'),
                    computer_built=state.get('computer', {}).get('built'), provider_auth='not checked: host does not expose an authentication probe')
        human = 'Host checks\n' + '\n'.join(f'{k}: {v}' for k, v in data.items())
    elif key.startswith('sapi '):
        agents = [client.agent(state, options.id)] if key == 'sapi show' else [a for a in state['agents'] if options.all or not a.get('retired')]
        rows = []
        for agent in agents:
            active = next((t['status'] for t in reversed(state['turns']) if t['agent'] == agent['id'] and t['status'] in {'queued', 'running'}), 'ready')
            row = dict(agent, state='retired' if agent.get('retired') else active, chief=agent['id'] == state.get('main_agent_id'))
            if key == 'sapi show': row['details'] = state.get('orchestration', {}).get(agent['id'], {})
            rows.append(row)
        data, human = {'sapis': rows}, renderer.sapis(rows)
    elif key.startswith('task '):
        tasks = client.tasks(state, options.sapi)
        if key == 'task show':
            data = next((t for t in tasks if t['id'] == options.id), None)
            require(data is not None, 'Task not found in selected Sapi scope.', 'NOT_FOUND', hint='Try --sapi all.')
            human = renderer.tasks([data], identities) + '\n\n' + data['body'] + '\nResult:\n' + (data.get('result') or '(no result yet)') + ('\nError: ' + data['error'] if data.get('error') else '')
        else:
            tasks = [t for t in tasks if options.tab == 'all' or (t['state'] in PAST) == (options.tab == 'past')]
            data, human = {'tasks': tasks, 'tab': options.tab}, renderer.tasks(tasks, identities)
    else:
        agent = client.agent(state, options.sapi)
        if key == 'memo show':
            data = client.request(client.agent_path(agent, 'notes'))
            human = renderer.avatar(agent) + agent['name'] + ' / Memo\n\n' + note_text(data['content'])
        elif key == 'history':
            turns = [t for t in state['turns'] if t['agent'] == agent['id']][-options.limit:]
            data = {'turns': turns}
            human = '\n\n'.join(f"{t['created']} | {t['status']} | {t['id']}\nYou: {t['input']}\n{renderer.avatar(agent)}{agent['name']}: {t.get('output') or t.get('error') or '(awaiting response)'}" for t in turns) or 'No conversations yet.'
        elif key == 'conversation watch': return observe(client, renderer, options, agent, options.id, state)
        else:
            payload = dict(text=options.message, flow='chat', **({'workload': options.workload} if options.workload else {})) if key == 'chat' else {}
            path = 'messages' if key == 'chat' else 'turns/' + quote(options.id, safe='') + '/' + key.split()[1]
            data = client.request(client.agent_path(agent, path), payload)
            human = renderer.avatar(agent) + ('Accepted' if key == 'chat' else data['status']) + ' | ' + data['id']
            if key == 'chat' and options.wait:
                if renderer.format == 'human': renderer.text(human)
                return observe(client, renderer, options, agent, data['id'])
            if key == 'chat':
                human += '\nWatch: conversation watch ' + data['id'] + ' --sapi ' + agent['id']
    renderer.emit(data, human)
    return 0

def shell(options, client, renderer):
    require(options.format == 'human', 'The interactive shell uses human output. Use individual commands for JSON.')
    selected = dict(id=options.sapi, name=options.sapi)
    defaults = {key: getattr(options, key) for key in GLOBALS}
    renderer.text('ABOUT\nSapiens4 / CORPORA\nLocal Sapis coordinated by Chief.\n')
    try:
        state = client.state()
        stats, tasks = status_data(state), state.get('workloads', [])
        renderer.text(f"STATS\nHost: online | Provider: {stats['provider']}\nSapis: {stats['active_sapis']} active | {stats['retired_sapis']} retired\n"
                      f"Work: {stats['running']} running | {stats['queued']} queued | {len(stats['waiting'])} waiting for you\n"
                      f"Tasks: {sum(t['state'] not in PAST for t in tasks)} upcoming | {sum(t['state'] in PAST for t in tasks)} past")
        selected = client.agent(state, options.sapi)
    except ClientError as error:
        renderer.emit(error=error)
    renderer.text('\nhelp for commands | exit to leave\n')
    if readline: readline.set_auto_history(False)
    while True:
        try:
            words = shlex.split(input(clean(renderer.avatar(selected) + selected['name'] + ' > ')))
            words = words[1:] if words[:1] == ['sapiens4'] else words
            if not words: continue
            if words[0] in {'exit', 'quit'}: raise EOFError
            if readline and words[0] != 'chat': readline.add_history(shlex.join(words))
            if words[0] == 'use':
                require(len(words) == 2, 'Use an exact Sapi ID or quoted name.')
                selected = client.agent(client.state(), words[1])
                renderer.text(renderer.avatar(selected) + 'Selected ' + selected['name'])
            else:
                main(words, selected['id'], defaults)
            renderer.text()
        except EOFError:
            renderer.text('Detached. CORPORA stays running.')
            return 0
        except KeyboardInterrupt:
            renderer.text('\nInput cleared. Type exit to leave.')
        except (ClientError, ValueError) as error:
            renderer.text('Error: ' + str(error))

def main(argv=None, selected='chief', defaults=None):
    argv = list(sys.argv[1:] if argv is None else argv) or (['shell'] if sys.stdin.isatty() else ['status'])
    requested = next((argv[i + 1] for i, arg in enumerate(argv[:-1]) if arg == '--format'), 'human')
    requested = next((arg.split('=', 1)[1] for arg in argv if arg.startswith('--format=')), requested)
    renderer = Renderer(requested if requested in {'human', 'json', 'jsonl', 'yaml'} else 'human')
    try:
        options = parse(argv, selected, defaults)
        return dispatch(options, Client(options.url), Renderer(options.format, options.plain, not options.no_animation))
    except (ClientError, KeyboardInterrupt) as error:
        error = ClientError('DETACHED', 'Interrupted; accepted server work is not cancelled.', 130) if isinstance(error, KeyboardInterrupt) else error
        renderer.emit(error=error, event='detached' if error.code == 'DETACHED' else 'error')
        return error.exit_code
    except BrokenPipeError:
        return 0

if __name__ == '__main__': raise SystemExit(main())
