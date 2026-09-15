"""Same-origin loopback HTTP API; no login or external Python dependencies."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
from urllib.parse import parse_qs, urlsplit

from .assets import asset
from .service import APIError


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, service):
        self.service = service
        super().__init__(("127.0.0.1", port), Handler)


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
        if not 0 < length <= 2_000_000:
            raise APIError(413, "Request body must be between 1 byte and 2 MB")
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
            if path == "/api/state":
                query = parse_qs(url.query)
                try:
                    after = int(query.get("after", ["0"])[0])
                except ValueError:
                    raise APIError(400, "after must be a nonnegative integer") from None
                if after < 0:
                    raise APIError(400, "after must be nonnegative")
                return self._send(200, service.snapshot(after))
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
            if path == "/api/agents" and self.command == "POST":
                return self._send(201, service.create_agent(data))
            if path == "/api/preferences" and self.command == "PUT":
                return self._send(200, service.save_preferences(data))
            if len(parts) >= 3 and parts[:2] == ["api", "agents"]:
                if len(parts) == 3 and self.command == "PUT":
                    return self._send(200, service.update_agent(parts[2], data))
                if len(parts) == 4 and parts[3] == "messages" and self.command == "POST":
                    return self._send(202, service.submit(parts[2], data))
                if len(parts) == 6 and parts[3] == "jobs" and self.command == "POST":
                    return self._send(200, service.job_action(parts[2], parts[4], parts[5]))
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
