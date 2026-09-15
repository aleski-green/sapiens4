"""Serve the pinned CORPORA shell with a small, checked integration seam."""
from .runtime import ROOT

UI = ROOT / "lab-corpora-ui"
WEB = ROOT / "web"


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise RuntimeError(f"CORPORA integration seam changed: {before[:80]!r}")
    return source.replace(before, after, 1)


def javascript():
    source = (UI / "workspace/app.js").read_text()
    source = replace_once(source,
                          "try { state = JSON.parse(localStorage.getItem(STORAGE)); } catch {}",
                          "state = makeInitialState(bootstrap);")
    source = replace_once(source, "\nrender();\n", "\n" + "\n".join((WEB / name).read_text() for name in ("names.js", "work-ui.js", "task-dialog.js", "mentions.js", "bridge.js")) + "\n")
    # These direct listeners must resolve the adapter functions at click time.
    for selector, function in (("add-agent", "addAgent"), ("autonomy-button", "autonomyDialog")):
        source = replace_once(source, f"$('#{selector}').addEventListener('click',{function});",
                              f"$('#{selector}').addEventListener('click',()=>{function}());")
    loader = (WEB / "bootstrap.js").read_text()
    return "(async () => {\n" + loader + "\n" + source + "\n})().catch(error => {\n" + """
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
    html = (UI / "workspace/index.html").read_text()
    html = replace_once(html, '<link rel="stylesheet" href="styles.css">',
                        '<link rel="stylesheet" href="styles.css"><link rel="stylesheet" href="/live.css">')
    for before, after in (
        ('id="agent-count">05', 'id="agent-count">0'),
        ('id="task-count">3', 'id="task-count">0'),
        ('id="resource-owner">In use · Aaron', 'id="resource-owner">Connecting…'),
        ('placeholder="Message Aaron…"', 'placeholder="Message your Sapi…"'),
        ('id="autonomy-label">Autonomous', 'id="autonomy-label">Connecting…'),
        ('aria-label="Workspace settings">AP', 'aria-label="Workspace settings">Human'),
    ):
        html = replace_once(html, before, after)
    return html


def asset(path):
    if path in {"/", "/workspace/", "/workspace/index.html"}:
        return "text/html; charset=utf-8", index().encode()
    if path == "/workspace/app.js":
        return "text/javascript; charset=utf-8", javascript().encode()
    if path == "/live.css":
        return "text/css; charset=utf-8", (WEB / "live.css").read_bytes()
    # Explicit public assets only: never expose submodule sources, runtime data or .git.
    files = {
        "/workspace/styles.css": ("text/css", UI / "workspace/styles.css"),
        "/assets/sapi-theme.css": ("text/css", UI / "assets/sapi-theme.css"),
        "/assets/sapi-theme.js": ("text/javascript", UI / "assets/sapi-theme.js"),
        "/assets/group-avatar.js": ("text/javascript", UI / "assets/group-avatar.js"),
    }
    if path in files:
        mime, file = files[path]
        return mime + "; charset=utf-8", file.read_bytes()
    return None
