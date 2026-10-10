"""Loopback-only CLI transport; never touches the database or starts a runner."""
import json, os, sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
class ClientError(Exception):
    def __init__(self, code, message, exit_code=1, hint=None):
        super().__init__(message)
        self.code, self.exit_code, self.hint = code, exit_code, hint
def require(condition, message, code='USAGE', exit_code=2, hint=None):
    if not condition: raise ClientError(code, message, exit_code, hint)
class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl): return None
class Client:
    def __init__(self, url=None, timeout=5):
        self.url = url or os.environ.get('SAPIENS4_URL')
        if not self.url:
            try:
                config = Path.home() / 'Library/Application Support/Sapiens4/config.json'
                if sys.platform == 'win32':
                    folder = os.environ.get('SAPIENS_DATA_DIR') or str(Path(os.environ.get('LOCALAPPDATA', Path.home() / 'AppData/Local')) / 'Sapiens4')
                    config = Path(folder) / 'config.json'
                port = json.loads(config.read_text(encoding='utf-8')).get('port', 4174)
            except (OSError, ValueError, AttributeError):
                port = 4174
            self.url = f'http://127.0.0.1:{port}'
        self.url = self.url.rstrip('/')
        try:
            parts = urlsplit(self.url)
            valid = (parts.scheme == 'http' and parts.hostname in {'127.0.0.1', 'localhost'}
                     and parts.port and not any((parts.username, parts.password, parts.path, parts.query, parts.fragment)))
        except ValueError:
            valid = False
        require(valid, 'Use http://127.0.0.1:PORT or http://localhost:PORT.')
        self.timeout, self.opener = timeout, build_opener(ProxyHandler({}), NoRedirect())
    def request(self, path, payload=None):
        request = Request(self.url + path, data=None if payload is None else json.dumps(payload).encode(), headers={
            'Content-Type': 'application/json', 'X-Sapiens-Local': '1'})
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                result = json.load(response)
        except HTTPError as error:
            try:
                message = json.loads(error.read()).get('error', str(error))
            except (ValueError, AttributeError):
                message = str(error)
            raise ClientError('HTTP_' + str(error.code), str(message)) from None
        except (URLError, OSError) as error:
            if payload is not None:
                raise ClientError('SUBMISSION_UNCERTAIN', 'No response received. The action may have been accepted; it was not retried.',
                    hint='Inspect history and tasks before submitting again.') from None
            raise ClientError('HOST_UNAVAILABLE', f'Cannot reach {self.url}: {error}', 3, 'Open Sapiens4, or start the host with ./start.sh.') from None
        except (ValueError, UnicodeError):
            raise ClientError('INVALID_RESPONSE', 'Host returned invalid JSON.' +
                              (' The action may have been accepted; it was not retried.' if payload is not None else '')) from None
        require(isinstance(result, dict), 'Expected an object from the host.', 'INVALID_RESPONSE', 1)
        return result
    def state(self):
        result = self.request('/api/state')
        require(all(isinstance(result.get(k), list) for k in ('agents', 'turns')), 'Host state lacks Sapis or conversations.', 'INVALID_RESPONSE', 1)
        return result
    def agent(self, state, selector):
        wanted = state.get('main_agent_id') if selector == 'chief' else selector
        found = [a for a in state['agents'] if a['id'] == wanted] or [a for a in state['agents'] if a['name'] == wanted]
        require(len(found) == 1, f'Expected one Sapi matching {selector!r}.', 'SAPI_NOT_FOUND', hint='Use show and copy an exact ID or unique name.')
        return found[0]
    def agent_path(self, agent, suffix):
        return '/api/agents/' + quote(agent['id'], safe='') + '/' + suffix
    def tasks(self, state, selector):
        agents = [a for a in state['agents'] if not a.get('retired')] if selector == 'all' else [self.agent(state, selector)]
        return list({task['id']: task for agent in agents
                     for task in self.request(self.agent_path(agent, 'tasks?format=json')).get('tasks', [])}.values())
