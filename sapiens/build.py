from pathlib import Path
import os
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
project = root / 'libs4/haskell'
build = project / '.build'
env = dict(os.environ, CABAL_DIR=str(project / '.cabal'))
args = ['cabal', '--project-file=' + str(project / 'cabal.project'), '--builddir=' + str(build)]
if not (project / '.cabal/packages/hackage.haskell.org/01-index.tar').exists():
    subprocess.run(['cabal', 'update'], env=env, check=True)
subprocess.run([*args, 'build', 'exe:sapiens-domain'], cwd=root, env=env, check=True)
binary = subprocess.check_output([*args, 'list-bin', 'exe:sapiens-domain'], cwd=root, env=env, text=True).strip()
target = root / '.build/domain' / ('sapiens-domain.exe' if sys.platform == 'win32' else 'sapiens-domain')
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(binary, target)
subprocess.run([sys.executable, str(project / "runtime.py"), str(target)], check=True)
print(target)
