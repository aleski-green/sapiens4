"""Serve Sapiens4's runtime UI from an explicit public asset allowlist."""
from .paths import ROOT

WEB = ROOT / "web"
SCRIPTS = ("bootstrap.js", "workspace/app.js", "names.js", "notes.js",
           "mentions.js",
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


def asset(path):
    if path in {"/", "/workspace/", "/workspace/index.html"}:
        return "text/html; charset=utf-8", index().encode()
    if path == "/workspace/app.js":
        return "text/javascript; charset=utf-8", javascript().encode()
    # Never expose Python sources, runtime data, or Git metadata.
    files = {
        "/live.css": ("text/css", "live.css"),
        "/workspace/styles.css": ("text/css", "workspace/styles.css"),
        "/assets/sapi-theme.css": ("text/css", "assets/sapi-theme.css"),
        "/assets/sapi-theme.js": ("text/javascript", "assets/sapi-theme.js"),
    }
    if path in files:
        mime, name = files[path]
        return mime + "; charset=utf-8", (WEB / name).read_bytes()
    return None
