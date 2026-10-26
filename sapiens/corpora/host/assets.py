from sapiens.paths import ROOT

WEB = ROOT / "web"
BUNDLE = ROOT / ".build" / "web"
PUBLIC_ASSETS = {
    '/remote-vendor.js': ('text/javascript', ROOT / 'libs4/web/remote-vendor.js'),
    '/corpora.css': ('text/css', WEB / 'theme/corpora.css'),
    '/remote-install.css': ('text/css', WEB / 'theme/remote-install.css'),
    '/manifest.webmanifest': ('application/manifest+json', WEB / 'shell/remote.webmanifest'),
    **{f'/app-icon-{size}.png': ('image/png', WEB / f'shell/app-icon-{size}.png') for size in (180, 192, 512)},
    **{f'/{name}.svg': ('image/svg+xml', WEB / f'shell/{name}.svg') for name in ('favicon', 'favicon-dark')},
    '/workspace/guest.js': ('text/javascript', BUNDLE / 'guest.js'),
    '/sw.js': ('text/javascript', BUNDLE / 'sw.js'),
    '/live.css': ('text/css', WEB / 'theme/live.css'),
    '/workspace/styles.css': ('text/css', WEB / 'theme/styles.css'),
    '/assets/sapi-theme.css': ('text/css', WEB / 'theme/sapi-theme.css'),
}


def javascript():
    path = BUNDLE / 'app.js'
    if not path.is_file():
        raise RuntimeError('Build the PureScript UI first: python3 web/shell/build.py (Node.js 22.5+ required).')
    return path.read_text(encoding='utf-8')


def index():
    return (WEB / 'shell/index.html').read_text(encoding='utf-8')


def asset(path):
    if path in {'/', '/workspace/', '/workspace/index.html'}:
        return 'text/html; charset=utf-8', index().encode()
    if path == '/workspace/app.js':
        return 'text/javascript; charset=utf-8', javascript().encode()
    if path in PUBLIC_ASSETS:
        mime, file = PUBLIC_ASSETS[path]
        return mime + '; charset=utf-8', file.read_bytes()
    return None
