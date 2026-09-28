"""Serve Sapiens4's runtime UI from an explicit public asset allowlist."""
from .paths import ROOT

WEB = ROOT / "web"
SCRIPTS = ("bootstrap.js", "workspace/app.js", "names.js", "work-ui.js",
           "task-dialog.js", "mentions.js", "mindmap.js", "usage.js",
           "workspaces.js", "bridge.js")


def javascript():
    source = "\n".join((WEB / name).read_text() for name in SCRIPTS)
    return "(async () => {\n" + source + "\n})().catch(error => {\n" + """
        document.body.replaceChildren();
        const panel = document.createElement('main');
        panel.style.cssText = 'padding:40px;font:16px monospace';
        const title = document.createElement('h1'); title.textContent = 'Sapiens4 could not connect';
        const detail = document.createElement('p'); detail.textContent = error.message;
        const retry = document.createElement('button'); retry.textContent = 'Retry connection';
        retry.onclick = () => location.reload();
        panel.append(title, detail, retry); document.body.append(panel);
    });
    """


def index():
    return (WEB / "workspace/index.html").read_text()


def memory_viewer():
    # Inline styles keep the memory iframe independent of its opaque origin.
    styles = "\n".join((WEB / name).read_text() for name in ("memory-tree.css", "mindmap-viewer.css"))
    header = '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
<title>Consolidated memory</title>'''
    return (header + '<style>' + styles + '</style></head><body>'
            + (WEB / 'memory-tree.html').read_text() + '</body></html>')


def asset(path):
    if path in {"/", "/workspace/", "/workspace/index.html"}:
        return "text/html; charset=utf-8", index().encode()
    if path == "/workspace/app.js":
        return "text/javascript; charset=utf-8", javascript().encode()
    if path == '/mindmap.html':
        return 'text/html; charset=utf-8', memory_viewer().encode()
    # Never expose Python sources, runtime data, or Git metadata.
    files = {
        "/live.css": ("text/css", "live.css"),
        "/workspace/styles.css": ("text/css", "workspace/styles.css"),
        "/assets/sapi-theme.css": ("text/css", "assets/sapi-theme.css"),
        "/assets/sapi-theme.js": ("text/javascript", "assets/sapi-theme.js"),
        "/assets/group-avatar.js": ("text/javascript", "assets/group-avatar.js"),
    }
    if path in files:
        mime, name = files[path]
        return mime + "; charset=utf-8", (WEB / name).read_bytes()
    return None
