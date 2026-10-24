"""Serve Sapiens4's runtime UI from an explicit public asset allowlist."""
from sapiens.paths import ROOT

WEB = ROOT / "web"
SCRIPTS = ("shell/application.js",)


# Never expose Python sources, runtime data, or Git metadata.
PUBLIC_ASSETS = {
    **{'/' + name + '.js': ('text/javascript', 'features/' + name + '.js') for name in
       ('corpora', 'relay-servers', 'remote-session', 'remote-transport', 'remote-code', 'remote-onboarding', 'remote-install')},
    '/remote-vendor.js': ('text/javascript', ROOT / 'libs4/web/remote-vendor.js'),
    '/corpora.css': ('text/css', 'theme/corpora.css'),
    '/remote-install.css': ('text/css', 'theme/remote-install.css'),
    '/manifest.webmanifest': ('application/manifest+json', 'shell/remote.webmanifest'),
    **{f'/app-icon-{size}.png': ('image/png', f'shell/app-icon-{size}.png') for size in (180, 192, 512)},
    '/sw.js': ('text/javascript', 'shell/sw.js'),
    "/live.css": ("text/css", "theme/live.css"),
    "/workspace/styles.css": ("text/css", "theme/styles.css"),
    "/assets/sapi-theme.css": ("text/css", "theme/sapi-theme.css"),
    "/assets/sapi-theme.js": ("text/javascript", "theme/sapi-theme.js"),
}

def javascript():
    return "\n".join((WEB / name).read_text(encoding='utf-8') for name in SCRIPTS)


def index():
    return (WEB / "shell/index.html").read_text(encoding='utf-8')


def asset(path):
    if path in {"/", "/workspace/", "/workspace/index.html"}:
        return "text/html; charset=utf-8", index().encode()
    if path == "/workspace/app.js":
        return "text/javascript; charset=utf-8", javascript().encode()
    if path in PUBLIC_ASSETS:
        mime, name = PUBLIC_ASSETS[path]
        return mime + "; charset=utf-8", (WEB / name).read_bytes()
    return None
