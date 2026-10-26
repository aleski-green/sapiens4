from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
for source, target in [('favicon.svg', 'AppIcon.ico'), ('favicon-dark.svg', 'AppIconDark.ico')]:
    subprocess.run(['node', str(ROOT / 'libs4/tools/svg-to-ico.cjs'),
                    str(ROOT / 'web/shell' / source), str(ROOT / 'windows' / target)], check=True)
