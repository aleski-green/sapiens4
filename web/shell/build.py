from pathlib import Path
import hashlib
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
LIBS = ROOT / 'libs4'
WORK = LIBS / 'purescript'
OUTPUT = ROOT / '.build' / 'web'


def build():
    inputs = sorted((ROOT / 'web').rglob('*.purs')) + sorted((WORK / 'src').rglob('*'))
    inputs += [WORK / 'spago.yaml', WORK / 'spago.lock', LIBS / 'package-lock.json', Path(__file__)]
    digest = hashlib.sha256()
    for path in inputs:
        if path.is_file():
            digest.update(str(path.relative_to(ROOT)).encode())
            digest.update(path.read_bytes())
    fingerprint = digest.hexdigest()
    stamp = OUTPUT / 'source.sha256'
    if stamp.exists() and stamp.read_text() == fingerprint and all((OUTPUT / name).is_file() for name in ('app.js', 'sw.js', 'guest.js')):
        return
    version = subprocess.check_output(['node', '--version'], text=True).strip().lstrip('v').split('.')
    if tuple(map(int, version[:2])) < (22, 5):
        raise SystemExit('Building the UI requires Node.js 22.5 or newer on PATH.')
    env = dict(os.environ)
    env['PATH'] = str(LIBS / 'node_modules' / '.bin') + os.pathsep + env.get('PATH', '')
    env['XDG_CACHE_HOME'] = str(LIBS / '.cache')
    env['npm_config_cache'] = str(LIBS / '.cache' / 'npm')
    if not (LIBS / 'node_modules' / '.bin' / 'purs').exists():
        subprocess.run(['npm', 'ci', '--prefix', str(LIBS)], env=env, check=True)
    subprocess.run(['spago', 'install', '--quiet'], cwd=WORK, env=env, check=True)
    sources = json.loads(subprocess.check_output(['spago', 'sources', '--json', '--quiet'], cwd=WORK, env=env))
    OUTPUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(['purs', 'compile', *sources, str(ROOT / 'web' / '**' / '*.purs'), '--output', str(OUTPUT / 'modules')], cwd=WORK, env=env, check=True)
    for module, filename in [('Sapiens.Main', 'app.js'), ('Sapiens.ServiceWorker', 'sw.js'), ('Sapiens.Guest', 'guest.js')]:
        entry = OUTPUT / (filename + '.entry.js')
        entry.write_text(f'import {{main}} from "./modules/{module}/index.js";main();\n')
        subprocess.run(['esbuild', str(entry), '--bundle', '--minify', '--format=iife', '--target=es2020', '--legal-comments=none', '--outfile=' + str(OUTPUT / filename)], env=env, check=True)
        entry.unlink()
    stamp.write_text(fingerprint)


if __name__ == '__main__':
    build()
