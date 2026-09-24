"""Install a managed local desktop app without moving the user's persistent state."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
HOME = Path.home() / 'Library/Application Support/Sapiens4'
APP = Path.home() / 'Applications/Sapiens4.app'


def install():
    HOME.mkdir(parents=True, exist_ok=True, mode=0o700)
    config_path = HOME / 'config.json'
    if not config_path.exists():
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        release = HOME / 'releases' / ('initial-' + sha[:12] + '-' + uuid.uuid4().hex[:8])
        release.mkdir(parents=True)
        paths = subprocess.check_output(['git', 'ls-files', '--recurse-submodules', '-z'], cwd=ROOT).decode().split('\0')
        for name in filter(None, paths):
            source, target = ROOT / name, release / name
            if source.is_file() or source.is_symlink():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target, follow_symlinks=False)
        # Include the desktop sources before their first commit as well.
        shutil.copytree(ROOT / 'macos', release / 'macos', dirs_exist_ok=True, ignore=shutil.ignore_patterns('__pycache__'))
        binary = ROOT / 'blindly4/.build/release/blindly4'
        if not binary.is_file():
            raise RuntimeError('Build Blindly4 with ./start.sh before installing the desktop app')
        dest = release / 'blindly4/.build/release/blindly4'
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, dest)
        # Keep existing absolute artifact references valid. Updates never replace this directory.
        data = ROOT / '.sapiens4'
        data.mkdir(exist_ok=True)
        (HOME / 'current.json').write_text(json.dumps(dict(root=str(release), sha=sha), indent=2))
        config_path.write_text(json.dumps(dict(data=str(data), legacy_root=str(ROOT), app=str(APP)), indent=2))
    shutil.copy2(ROOT / 'macos/updater.py', HOME / 'updater.py')
    env = dict(os.environ, SAPIENS_DESKTOP_HOME=str(HOME), SAPIENS_PYTHON=sys.executable)
    subprocess.run([str(ROOT / 'macos/build.sh')], env=env, check=True)
    APP.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', str(ROOT / '.build/macos/Sapiens4.app'), str(APP)], check=True)
    print(f'Installed {APP}\nManaged code: {HOME}\nExisting data: {json.loads(config_path.read_text())["data"]}')

if __name__ == '__main__':
    install()
