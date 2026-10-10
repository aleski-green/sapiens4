"""Same-origin loopback HTTP API; no login or external Python dependencies."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import json
import logging

from sapiens.corpora.host.remote_bridge import RemoteBridge
from sapiens.corpora.host.assets import asset
from sapiens.corpora.host.corpora_api import dispatch
from sapiens.validation import APIError


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
        path = urlsplit(self.path).path
        if self.command == 'GET':
            if path == '/api/remote':
                return self._send(200, self.server.remote.status())
            if path == '/':
                self.send_response(302)
                self.send_header('Location', '/workspace/')
                self.end_headers()
                return
            found = asset(path)
            if found:
                return self._send(200, found[1], found[0])
        data = self._body() if write else None
        if self.command == 'POST' and path.startswith('/api/remote/'):
            if path == '/api/remote/pair':
                return self._send(201, self.server.remote.create(data))
            if path == '/api/remote/approve':
                return self._send(200, self.server.remote.approve(data))
            if path == '/api/remote/revoke':
                return self._send(200, self.server.remote.revoke())
        return self._send(*dispatch(self.server.service, self.command, self.path, data))

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
