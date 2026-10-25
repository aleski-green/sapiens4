from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
LIBS = ROOT / 'libs4'
WORK = LIBS / 'purescript'
OUTPUT = ROOT / '.build' / 'web'


def npm_tool(name, env):
    # CreateProcess does not search PATHEXT for npm's Windows command shims.
    commands = [name + '.exe', name + '.cmd'] if os.name == 'nt' else [name]
    search_path = str(LIBS / 'node_modules' / '.bin') + os.pathsep + env['PATH']
    executable = next((path for command in commands
                       if (path := shutil.which(command, path=search_path))), None)
    if executable is None:
        raise SystemExit(f'Building the UI requires {name} on PATH.')
    return executable


def build():
    inputs = sorted((ROOT / 'web').rglob('*.purs')) + sorted((WORK / 'src').rglob('*'))
    inputs += [WORK / 'spago.yaml', WORK / 'spago.lock', LIBS / 'package-lock.json', Path(__file__).resolve()]
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
    if os.name != 'nt':
        env['PATH'] = str(LIBS / 'node_modules' / '.bin') + os.pathsep + env.get('PATH', '')
    env['XDG_CACHE_HOME'] = str(LIBS / '.cache')
    if os.name == 'nt':
        env['LOCALAPPDATA'] = str(LIBS / '.cache')
    env['npm_config_cache'] = str(LIBS / '.cache' / 'npm')
    if not (LIBS / 'node_modules' / '.bin' / 'purs').exists():
        subprocess.run([npm_tool('npm', env), 'ci', '--prefix', str(LIBS)], env=env, check=True)
    if os.name == 'nt':
        # Spago spawns purs without a shell; a .cmd shim cannot be executed that
        # way. Keep npm's .bin directory off its PATH and expose the pinned PE
        # binary as purs.exe without modifying the installed package.
        native_bin = LIBS / '.cache' / 'bin'
        native_bin.mkdir(parents=True, exist_ok=True)
        shutil.copy2(LIBS / 'node_modules' / 'purescript' / 'purs.bin', native_bin / 'purs.exe')
        env['PATH'] = str(native_bin) + os.pathsep + env['PATH']
    subprocess.run([npm_tool('spago', env), 'install', '--quiet'], cwd=WORK, env=env, check=True)
    sources = json.loads(subprocess.check_output([npm_tool('spago', env), 'sources', '--json', '--quiet'], cwd=WORK, env=env))
    OUTPUT.mkdir(parents=True, exist_ok=True)
    subprocess.run([npm_tool('purs', env), 'compile', *sources, str(ROOT / 'web' / '**' / '*.purs'), '--output', str(OUTPUT / 'modules')], cwd=WORK, env=env, check=True)
    for module, filename in [('Sapiens.Main', 'app.js'), ('Sapiens.ServiceWorker', 'sw.js'), ('Sapiens.Guest', 'guest.js')]:
        entry = OUTPUT / (filename + '.entry.js')
        entry.write_text(f'import {{main}} from "./modules/{module}/index.js";main();\n')
        subprocess.run([npm_tool('esbuild', env), str(entry), '--bundle', '--minify', '--format=iife', '--target=es2020', '--legal-comments=none', '--outfile=' + str(OUTPUT / filename)], env=env, check=True)
        entry.unlink()
    stamp.write_text(fingerprint)


if __name__ == '__main__':
    build()
