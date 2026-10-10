"""CORPORA operations shared by loopback HTTP and authenticated remote devices."""
from urllib.parse import parse_qs, unquote, urlsplit

from sapiens.corpora.sapis.attachments import create_attachment
from sapiens.corpora.sapis.notes import Notes
from sapiens.corpora.host.delegation import yaml_text
from sapiens.validation import APIError


def reply(status, value, mime="application/json; charset=utf-8"):
    return status, value, mime


def dispatch(service, method, target, data=None):
    url = urlsplit(target)
    path = url.path
    parts = path.strip("/").split("/")
    write = method in {"POST", "PUT"}
    if write and not isinstance(data, dict):
        raise APIError(400, "Expected a JSON object")
    if method == "GET":
        if len(parts) == 6 and parts[0] == 'api' and parts[1] in {'agents', 'groups'} and parts[3] == 'browser' and parts[5] == 'content':
            with service._lock:
                owner = service.groups.workspace_owner(parts[2]) if parts[1] == 'groups' else service._agent(parts[2])
                return reply(200, service.workspace.text(owner, parts[4]))
        if path == '/api/decision-prompts':
            return reply(200, {'prompts': service.delegation.templates()})
        if len(parts) == 4 and parts[:2] == ['api', 'agents'] and parts[3] == 'tasks':
            service._agent(parts[2])
            if parse_qs(url.query).get('format') == ['json']:
                return reply(200, service.delegation.task_list(parts[2]))
            value = service.delegation.tasks(parts[2], full=True)
            return reply(200, (yaml_text(value) + '\n').encode(), 'application/yaml; charset=utf-8')
        if path == '/api/groups':
            with service._lock:
                return reply(200, {'groups': service.groups.snapshot()})
        if len(parts) == 3 and parts[:2] == ['api', 'groups']:
            with service._lock:
                return reply(200, service.groups.get(parts[2]))
        if path == "/api/state":
            return reply(200, service.snapshot())
        if len(parts) == 4 and parts[0] == 'api' and parts[1] in {'agents', 'groups'} and parts[3] == 'notes':
            with service._lock:
                notes = Notes(service.groups.folder(parts[2]) if parts[1] == 'groups'
                              else service.workspace.root(service._agent(parts[2])))
                image = parse_qs(url.query).get('image', [None])[0]
                return reply(200, *notes.image(unquote(image))) if image else reply(200, notes.read())
        if path == "/api/health":
            return reply(200, {"status": "ok", "provider": "codex"})
    elif write:
        if len(parts) == 3 and parts[:2] == ['api', 'decision-prompts'] and method == 'PUT':
            return reply(200, service.delegation.edit_template(parts[2], data))
        if path == '/api/groups' and method == 'POST':
            return reply(201, service.groups.create(data))
        if len(parts) >= 3 and parts[:2] == ['api', 'groups']:
            gid = parts[2]
            with service._lock:
                if len(parts) == 3 and method == 'PUT':
                    return reply(200, service.groups.update(gid, data))
                service.groups.get(gid)
                if len(parts) == 4 and parts[3] == 'attachments' and method == 'POST':
                    return reply(201, create_attachment(service, gid, data))
                if len(parts) == 4 and parts[3] == 'messages' and method == 'POST':
                    return reply(202, service.groups.chat.submit(gid, data))
                if len(parts) == 4 and parts[3] == 'tasks' and method == 'POST':
                    return reply(201, service.groups.work.create(gid, data))
                if len(parts) == 5 and parts[3] == 'tasks' and method == 'PUT':
                    return reply(200, service.groups.work.update(gid, parts[4], data))
                if len(parts) == 6 and parts[3] == 'tasks' and parts[5] == 'run' and method == 'POST':
                    return reply(202, service.groups.work.run(gid, parts[4], data.get('revision')))
                if len(parts) == 6 and parts[3] == 'calls' and method == 'POST':
                    return reply(200, service.groups.chat.action(gid, parts[4], parts[5]))
                if len(parts) == 4 and parts[3] == 'browser' and method == 'POST':
                    return reply(200, service.workspace.observed(service.groups.workspace_owner(gid), data))
                if len(parts) == 4 and parts[3] == 'control' and method == 'POST':
                    service.groups.get(gid, active=True)
                    op = data.get('op', '')
                    if not op.startswith('workspace_'):
                        raise APIError(400, 'Only workspace operations are supported here')
                    return reply(200, service.workspace.control(service.groups.workspace_owner(gid), op.removeprefix('workspace_'), data))
        if path == "/api/agents" and method == "POST":
            return reply(201, service.create_agent(data))
        if path == "/api/preferences" and method == "PUT":
            return reply(200, service.save_preferences(data))
        if len(parts) >= 3 and parts[:2] == ["api", "agents"]:
            if len(parts) == 3 and method == "PUT":
                return reply(200, service.update_agent(parts[2], data))
            if len(parts) == 4 and parts[3] == "attachments" and method == "POST":
                return reply(201, create_attachment(service, parts[2], data))
            if len(parts) == 4 and parts[3] == "messages" and method == "POST":
                return reply(202, service.submit(parts[2], data))
            if len(parts) == 4 and parts[3] == "browser" and method == "POST":
                with service._lock:
                    return reply(200, service.workspace.observed(service._agent(parts[2]), data))
            if len(parts) == 4 and parts[3] == "control" and method == "POST":
                return reply(200, service.orchestration.control(parts[2], data))
            if len(parts) == 6 and parts[3] == "turns" and method == "POST":
                return reply(200, service.turn_action(parts[2], parts[4], parts[5]))
    raise APIError(404, "Not found")
