"""Local desktop release manager. Standard library only; never resets a checkout."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

UPSTREAM = 'https://github.com/aleski-green/sapiens4.git'
BASE = 'http://127.0.0.1:4174'


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(value, indent=2))
    os.replace(temp, path)


def command(args, cwd=None, timeout=300):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout or 'Command failed')[-3000:])
    return result.stdout.strip()


def replace_app(staged, installed):
    """Atomically exchange bundles on macOS; never leave the launch path missing."""
    if not installed.exists():
        os.replace(staged, installed)
        return False
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(staged), os.fsencode(installed), 0x00000002) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return True


def request(path):
    with urllib.request.urlopen(BASE + path, timeout=5) as response:
        if not response.headers.get('Server', '').startswith('Sapiens4'):
            raise RuntimeError('Port 4174 belongs to another application')
        return json.load(response)


def healthy():
    try:
        return request('/api/health').get('status') == 'ok'
    except urllib.error.URLError:
        return False


def busy(state):
    return bool(state.get('computer', {}).get('owner')) or any(
        j.get('status') in {'queued', 'running'} for j in state.get('jobs', []))


class Manager:
    def __init__(self, home):
        self.home = Path(home).resolve()
        self.config = json.loads((self.home / 'config.json').read_text())
        self.data = Path(self.config['data'])
        self.status_file = self.home / 'status.json'

    def status(self, phase, message, **extra):
        atomic(self.status_file, dict(phase=phase, message=message, **extra))

    def current(self):
        return json.loads((self.home / 'current.json').read_text())

    def check(self):
        output = command(['git', 'ls-remote', UPSTREAM, 'refs/heads/main'], timeout=45)
        sha = output.split()[0] if output else ''
        if not re.fullmatch('[0-9a-f]{40}', sha):
            raise RuntimeError('GitHub did not return a valid main revision')
        current = self.current()
        available = sha != current['sha']
        self.status('available' if available else 'current',
                    f"Update available: main {sha[:7]}" if available else 'Sapiens4 is up to date',
                    sha=sha, current=current['sha'], checked_at=time.time())
        return sha

    def prepare(self, sha):
        destination = self.home / 'releases' / (sha + '-' + uuid.uuid4().hex[:8])
        self.status('preparing', 'Downloading main and pinned submodules…')
        command(['git', 'clone', '--no-checkout', '--single-branch', '--branch', 'main', UPSTREAM, str(destination)], timeout=600)
        command(['git', 'checkout', '--detach', sha], cwd=destination)
        command(['git', 'submodule', 'update', '--init', '--recursive'], cwd=destination, timeout=900)
        self.status('preparing', 'Building Blindly4…')
        command(['xcrun', 'swift', 'build', '--package-path', str(destination / 'blindly4'), '-c', 'release'], timeout=1200)
        command([sys.executable, '-c', 'from sapiens.assets import index,javascript; index(); javascript(); from sapiens.service import Service'], cwd=destination)
        release = dict(root=str(destination), sha=sha)
        if (destination / 'macos/build.sh').is_file() and self.config.get('app'):
            self.status('preparing', 'Building the updated desktop app…')
            env = dict(os.environ, SAPIENS_DESKTOP_HOME=str(self.home), SAPIENS_PYTHON=sys.executable)
            build = subprocess.run([str(destination / 'macos/build.sh')], cwd=destination, env=env, capture_output=True, text=True, timeout=600)
            if build.returncode:
                raise RuntimeError('Desktop build failed: ' + build.stderr[-2000:])
            app = destination / '.build/macos/Sapiens4.app'
            command(['codesign', '--verify', '--strict', str(app)])
            import plistlib
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            launcher = plistlib.loads((app / 'Contents/Resources/Launcher.plist').read_bytes())
            if info.get('CFBundleIdentifier') != 'com.sapiens4.desktop' or launcher.get('ManagedHome') != str(self.home):
                raise RuntimeError('New desktop build does not support this managed installation')
            release['desktop'] = str(app)
        return release

    def server_pid(self):
        result = subprocess.run(['/usr/sbin/lsof', '-nP', '-iTCP:' + str(self.config.get('port', 4174)), '-sTCP:LISTEN', '-t'], capture_output=True, text=True)
        pids = set(result.stdout.split())
        if len(pids) != 1:
            raise RuntimeError('Cannot identify one local server process; update stopped safely')
        pid = int(pids.pop())
        args = command(['/bin/ps', '-p', str(pid), '-o', 'command='])
        cwd = command(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'])
        allowed = {self.current()['root'], self.config['legacy_root']}
        journal = self.home / 'transaction.json'
        if journal.exists():
            tx = json.loads(journal.read_text())
            allowed.update([tx['old']['root'], tx['new']['root']])
        actual = next((line[1:] for line in cwd.splitlines() if line.startswith('n')), '')
        if actual not in allowed or not ('-m sapiens' in args or ('updater.py' in args and ' serve ' in args)):
            raise RuntimeError('The server is not owned by this installation; update stopped safely')
        return pid

    def stop(self):
        pid = self.server_pid()
        os.kill(pid, signal.SIGTERM)
        # Graceful shutdown never kills a bounded agent call. host.lock is authoritative.
        lock = self.data / 'host.lock'
        with lock.open('a') as handle:
            deadline = time.monotonic() + 7200
            while True:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(handle, fcntl.LOCK_UN)
                    return
                except BlockingIOError:
                    if time.monotonic() > deadline:
                        raise RuntimeError('Server is still finishing work. It was not force-quit; try again after it stops.')
                    time.sleep(1)

    def spawn(self, release, paused=False):
        token = uuid.uuid4().hex
        activation = self.home / ('activate-' + token)
        if not paused:
            activation.touch()
        logfile = self.home / 'desktop-server.log'
        with logfile.open('ab') as log:
            proc = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--home', str(self.home),
                                     'serve', '--root', release['root'], '--activation', str(activation)],
                                    cwd=release['root'], stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                    start_new_session=True)
        try:
            for _ in range(90):
                if proc.poll() is not None:
                    raise RuntimeError('New server exited; see desktop-server.log')
                try:
                    health = request('/api/health')
                    if health.get('desktop_pid') == proc.pid:
                        return proc, activation
                except urllib.error.URLError:
                    pass
                time.sleep(1)
            raise RuntimeError('New server did not become ready within 90 seconds')
        except BaseException:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=30)  # Candidate is still paused; no agent call is killed.
            activation.unlink(missing_ok=True)
            raise

    def recover(self):
        journal = self.home / 'transaction.json'
        if not journal.exists():
            return
        tx = json.loads(journal.read_text())
        if tx.get('committed'):
            # Commit precedes activation. Complete activation after a helper crash.
            Path(tx['activation']).touch()
            journal.unlink()
            return
        if healthy():
            self.stop()
        backup = Path(tx['backup'])
        if backup.exists():
            failed = self.home / 'backups' / ('failed-' + uuid.uuid4().hex)
            if self.data.exists():
                shutil.move(str(self.data), str(failed))
            shutil.copytree(backup, self.data, symlinks=True)
        atomic(self.home / 'current.json', tx['old'])
        self.spawn(tx['old'])
        journal.unlink()
        self.status('error', 'Previous version restored after an incomplete update. Your data backup was preserved.')

    def launch(self):
        self.recover()
        if not healthy():
            self.spawn(self.current())

    def update(self):
        self.recover()
        sha = self.check()
        old = self.current()
        if sha == old['sha']:
            return
        new = self.prepare(sha)
        self.status('waiting', 'Update ready. Waiting for active and queued agent work to finish…')
        while healthy() and busy(request('/api/state')):
            time.sleep(10)
        self.status('installing', 'Saving state and switching versions…')
        if healthy():
            self.stop()
        backup = self.home / 'backups' / (time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
        # Server is stopped: include SQLite WALs, agent state, artifacts and preferences together.
        try:
            with (self.data / 'host.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                shutil.copytree(self.data, backup, symlinks=True)
        except Exception:
            if not healthy():
                self.spawn(old)
            raise
        tx = dict(old=old, new=new, backup=str(backup), committed=False)
        atomic(self.home / 'transaction.json', tx)
        try:
            proc, activation = self.spawn(new, paused=True)
            tx['activation'] = str(activation)
            atomic(self.home / 'current.json', new)
            tx['committed'] = True
            atomic(self.home / 'transaction.json', tx)
            activation.touch()  # Only now may jobs or mutating HTTP requests run.
            (self.home / 'transaction.json').unlink()
        except Exception:
            self.recover()
            raise
        desktop_revision = None
        if new.get('desktop'):
            app = Path(self.config['app'])
            staged = app.with_name('Sapiens4-staged-' + uuid.uuid4().hex + '.app')
            previous = self.home / 'backups' / ('desktop-' + uuid.uuid4().hex + '.app')
            command(['ditto', new['desktop'], str(staged)])
            exchanged = replace_app(staged, app)
            if exchanged:
                shutil.move(str(staged), str(previous))
            helper = app / 'Contents/Resources/updater.py'
            if helper.is_file():
                shutil.copy2(helper, self.home / 'updater-next.py')
                os.replace(self.home / 'updater-next.py', self.home / 'updater.py')
            desktop_revision = sha
        self.status('current', f'Updated to main {sha[:7]}', sha=sha, checked_at=time.time(), desktop_revision=desktop_revision)


def serve(manager, root, activation):
    """Start compatible upstream code with jobs held until update health verification."""
    sys.path.insert(0, root)
    from sapiens.assets import index, javascript
    from sapiens.service import Service
    from sapiens.server import Server, Handler
    index(), javascript()
    service = Service(manager.data, start_worker=False)
    active = threading.Event()
    class DesktopHandler(Handler):
        def _route(self):
            if self.path == '/api/health' and self.command == 'GET':
                self._origin()
                return self._send(200, dict(status='ok', provider='codex', desktop_pid=os.getpid(), desktop_active=active.is_set()))
            if not active.is_set():
                self._origin()
                return self._send(503, {'error': 'Desktop update is being verified; retry shortly'})
            return super()._route()
    try:
        server = Server(manager.config.get('port', 4174), service)
    except BaseException:
        service.close()
        raise
    server.RequestHandlerClass = DesktopHandler
    stopping = threading.Event()
    def stop(*_):
        if stopping.is_set():
            return
        stopping.set()
        # Stop admission/scheduling while leaving host-control available to a run
        # that raced with the idle check. Never interrupt its API calls.
        service._stopping.set()
        service._queue.put(None)
        def drain():
            if service.worker:
                service.worker.join()
            server.shutdown()
        threading.Thread(target=drain, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    def activate():
        deadline = time.monotonic() + 120
        while not stopping.is_set():
            if Path(activation).exists():
                Path(activation).unlink(missing_ok=True)
                service.start()
                active.set()
                return
            if time.monotonic() > deadline:
                stop()
                return
            time.sleep(0.2)
    threading.Thread(target=activate, daemon=True).start()
    try:
        server.serve_forever()
    finally:
        stopping.set()
        server.server_close()
        service.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', required=True)
    parser.add_argument('action', choices=['check', 'update', 'launch', 'serve'])
    parser.add_argument('--root')
    parser.add_argument('--activation')
    args = parser.parse_args()
    manager = Manager(args.home)
    global BASE
    BASE = 'http://127.0.0.1:' + str(manager.config.get('port', 4174))
    if args.action == 'serve':
        return serve(manager, args.root, args.activation)
    with (manager.home / 'updater.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return  # A detached update may outlive the desktop window.
        try:
            getattr(manager, args.action)()
        except Exception as error:
            manager.status('error', str(error))
            print(str(error), file=sys.stderr)
            return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
