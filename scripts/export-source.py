#!/usr/bin/env python3
"""Export reviewed source with fresh history. Never copies the old Git directory."""
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
destination = pathlib.Path(sys.argv[1]).resolve()
if destination.exists() or root in destination.parents:
    raise SystemExit('Choose a new directory outside the source checkout.')
tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
additions = ['LICENSE', 'CONTRIBUTING.md', 'SECURITY.md', 'CHANGELOG.md',
             'THIRD_PARTY_NOTICES.md', 'docs/RELEASE.md', 'docs/PRIVACY.md',
             'scripts/package-app.sh', 'scripts/export-source.py']
additions += [str(p.relative_to(root)) for p in (root / '.github').rglob('*') if p.is_file()]
paths = sorted(set(filter(None, tracked + additions)))
for name in paths:
    source = root / name
    if source.is_symlink():
        raise SystemExit(f'Review symlink before export: {name}')
    if not source.is_file():
        raise SystemExit(f'Missing source: {name}')
destination.mkdir(parents=True)
for name in paths:
    target = destination / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / name, target)
def git(*args):
    subprocess.run(['git', *args], cwd=destination, check=True)
git('init', '-b', 'main')
git('config', 'user.name', 'jxu')
git('config', 'user.email', '50418566+jxu-dev-c@users.noreply.github.com')
git('add', '.')
git('-c', 'commit.gpgsign=false', 'commit', '-m', 'Initial open-source preparation snapshot')
print(destination)
