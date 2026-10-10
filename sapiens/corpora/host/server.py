"""Same-origin loopback HTTP API; no login or external Python dependencies."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit
import json
import logging

from sapiens.corpora.host.remote_bridge import RemoteBridge
from sapiens.corpora.host.assets import asset
from sapiens.corpora.sapis.attachments import create_attachment
from sapiens.validation import APIError
from sapiens.corpora.sapis.notes import Notes
from sapiens.corpora.host.delegation import yaml_text


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, service):
        self.service = service
        super().__init__(("127.0.0.1", port), Handler)
        with service._lock:
            service.orchestration.attach(f"http://127.0.0.1:{self.server_port}")
        self.remote = RemoteBridge(service)

    def server_close(self):
        if hasattr(self, "remote"):
            self.remote.close()
        super().server_close()


class Handler(BaseHTTPRequestHandler):
    server_version = "Sapiens4"

    def log_message(self, format, *args):
        # Do not copy chat text, query strings or job output into access logs.
        pass

    def _send(self, status, value, mime="application/json; charset=utf-8"):
        raw = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(raw)

    def _origin(self, write=False):
        port = self.server.server_port
        allowed = {f"127.0.0.1:{port}", f"localhost:{port}"}
        if self.headers.get("Host") not in allowed:
            raise APIError(403, "Loopback host required")
        origin = self.headers.get("Origin")
        if origin is not None and origin != "http://" + self.headers.get("Host", ""):
            raise APIError(403, "Same-origin request required")
        if write and (self.headers.get("X-Sapiens-Local") != "1" or
                      self.headers.get_content_type() != "application/json"):
            raise APIError(403, "Local JSON request required")

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise APIError(400, "Invalid content length") from None
        maximum = 15_000_000 if urlsplit(self.path).path.endswith("/attachments") else 2_000_000
        if not 0 < length <= maximum:
            raise APIError(413, "Request body is empty or too large")
        try:
            data = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeError):
            raise APIError(400, "Invalid JSON") from None
        if not isinstance(data, dict):
            raise APIError(400, "Expected a JSON object")
        return data

    def _route(self):
        write = self.command in {"POST", "PUT"}
        self._origin(write)
        url = urlsplit(self.path)
        path = url.path
        parts = path.strip("/").split("/")
        service = self.server.service
        if self.command == "GET":
            if len(parts) == 6 and parts[0] == 'api' and parts[1] in {'agents', 'groups'} and parts[3] == 'browser' and parts[5] == 'content':
                with service._lock:
                    owner = service.groups.workspace_owner(parts[2]) if parts[1] == 'groups' else service._agent(parts[2])
                    return self._send(200, service.workspace.text(owner, parts[4]))
            if path == '/api/decision-prompts':
                return self._send(200, {'prompts': service.delegation.templates()})
            if len(parts) == 4 and parts[:2] == ['api', 'agents'] and parts[3] == 'tasks':
                service._agent(parts[2])
                if parse_qs(url.query).get('format') == ['json']:
                    return self._send(200, service.delegation.task_list(parts[2]))
                value = service.delegation.tasks(parts[2], full=True)
                return self._send(200, (yaml_text(value) + '\n').encode(), 'application/yaml; charset=utf-8')
            if path == '/api/groups':
                with service._lock:
                    return self._send(200, {'groups': service.groups.snapshot()})
            if len(parts) == 3 and parts[:2] == ['api', 'groups']:
                with service._lock:
                    return self._send(200, service.groups.get(parts[2]))
            if path == "/api/remote":
                return self._send(200, self.server.remote.status())
            if path == "/api/state":
                return self._send(200, service.snapshot())
            if len(parts) == 4 and parts[0] == 'api' and parts[1] in {'agents', 'groups'} and parts[3] == 'notes':
                with service._lock:
                    notes = Notes(service.groups.folder(parts[2]) if parts[1] == 'groups'
                                  else service.workspace.root(service._agent(parts[2])))
                    image = parse_qs(url.query).get('image', [None])[0]
                    return self._send(200, *notes.image(unquote(image))) if image else self._send(200, notes.read())
            if path == "/api/health":
                return self._send(200, {"status": "ok", "provider": "codex"})
            if path == "/":
                self.send_response(302)
                self.send_header("Location", "/workspace/")
                self.end_headers()
                return
            found = asset(path)
            if found:
                return self._send(200, found[1], found[0])
        elif write:
            data = self._body()
            if path.startswith('/api/remote/') and self.command == 'POST':
                action = path.removeprefix('/api/remote/')
                if action == 'pair':
                    return self._send(201, self.server.remote.create(data))
                if action == 'approve':
                    return self._send(200, self.server.remote.approve(data))
                if action == 'revoke':
                    return self._send(200, self.server.remote.revoke())
            if len(parts) == 3 and parts[:2] == ['api', 'decision-prompts'] and self.command == 'PUT':
                return self._send(200, service.delegation.edit_template(parts[2], data))
            if path == '/api/groups' and self.command == 'POST':
                return self._send(201, service.groups.create(data))
            if len(parts) >= 3 and parts[:2] == ['api', 'groups']:
                gid = parts[2]
                with service._lock:
                    if len(parts) == 3 and self.command == 'PUT':
                        return self._send(200, service.groups.update(gid, data))
                    service.groups.get(gid)
                    if len(parts) == 4 and parts[3] == 'attachments' and self.command == 'POST':
                        return self._send(201, create_attachment(service, gid, data))
                    if len(parts) == 4 and parts[3] == 'messages' and self.command == 'POST':
                        return self._send(202, service.groups.chat.submit(gid, data))
                    if len(parts) == 4 and parts[3] == 'tasks' and self.command == 'POST':
                        return self._send(201, service.groups.work.create(gid, data))
                    if len(parts) == 5 and parts[3] == 'tasks' and self.command == 'PUT':
                        return self._send(200, service.groups.work.update(gid, parts[4], data))
                    if len(parts) == 6 and parts[3] == 'tasks' and parts[5] == 'run' and self.command == 'POST':
                        return self._send(202, service.groups.work.run(gid, parts[4], data.get('revision')))
                    if len(parts) == 6 and parts[3] == 'calls' and self.command == 'POST':
                        return self._send(200, service.groups.chat.action(gid, parts[4], parts[5]))
                    if len(parts) == 4 and parts[3] == 'browser' and self.command == 'POST':
                        return self._send(200, service.workspace.observed(service.groups.workspace_owner(gid), data))
                    if len(parts) == 4 and parts[3] == 'control' and self.command == 'POST':
                        service.groups.get(gid, active=True)
                        op = data.get('op', '')
                        if not op.startswith('workspace_'):
                            raise APIError(400, 'Only workspace operations are supported here')
                        return self._send(200, service.workspace.control(service.groups.workspace_owner(gid), op.removeprefix('workspace_'), data))
            if path == "/api/agents" and self.command == "POST":
                return self._send(201, service.create_agent(data))
            if path == "/api/preferences" and self.command == "PUT":
                return self._send(200, service.save_preferences(data))
            if len(parts) >= 3 and parts[:2] == ["api", "agents"]:
                if len(parts) == 3 and self.command == "PUT":
                    return self._send(200, service.update_agent(parts[2], data))
                if len(parts) == 4 and parts[3] == "attachments" and self.command == "POST":
                    return self._send(201, create_attachment(service, parts[2], data))
                if len(parts) == 4 and parts[3] == "messages" and self.command == "POST":
                    return self._send(202, service.submit(parts[2], data))
                if len(parts) == 4 and parts[3] == "browser" and self.command == "POST":
                    with service._lock:
                        return self._send(200, service.workspace.observed(service._agent(parts[2]), data))
                if len(parts) == 4 and parts[3] == "control" and self.command == "POST":
                    return self._send(200, service.orchestration.control(parts[2], data))
                if len(parts) == 6 and parts[3] == "turns" and self.command == "POST":
                    return self._send(200, service.turn_action(parts[2], parts[4], parts[5]))
        raise APIError(404, "Not found")

    def _handle(self):
        try:
            self._route()
        except APIError as error:
            self._send(error.status, {"error": str(error)})
        except ValueError as error:
            self._send(409, {"error": str(error)})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            logging.exception("Request failed")
            self._send(500, {"error": "Local server error; see the server terminal"})

    do_GET = _handle
    do_POST = _handle
    do_PUT = _handle
