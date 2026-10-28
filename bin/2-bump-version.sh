#!/usr/bin/env bash
# Bump the app version, commit, and push main (may trigger GitHub Actions).
# Usage: ./bin/2-bump-version.sh [patch|minor|major]
#   patch          Default: increment patch and build number.
#   minor          Increment minor and build number.
#   major          Increment major and build number.
#   -h, --help     Show this help.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then sed -n "2,10p" "$0" | sed "s/^# //"; exit 0; fi
kind="${1:-patch}"
case "$kind" in patch|minor|major) ;; *) echo 'Usage: ./bin/2-bump-version.sh [patch|minor|major]' >&2;exit 2;;esac
[[ -d .git ]] || { echo 'Not a git repository' >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo 'Switch to the main branch before bumping/pushing.' >&2; exit 1; }
remote="$(git remote get-url origin 2>/dev/null || true)"
case "$remote" in
  git@github.com:ssnanda/taptether-source.git|ssh://git@github.com/ssnanda/taptether-source.git|https://github.com/ssnanda/taptether-source.git|https://github.com/ssnanda/taptether-source) ;;
  *) echo "Refusing push: origin is not ssnanda/taptether-source ($remote)" >&2;exit 1;;
esac
# Avoid mixing a version-only commit with already-staged unrelated edits.
if ! git diff --cached --quiet; then echo 'Commit/unstage currently staged changes first.' >&2;exit 1;fi
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required' >&2; exit 1; }
python3 - "$kind" <<'TT_BUMPPY'
import re,sys
from pathlib import Path
kind=sys.argv[1]
p=Path('VERSION')
q=Path('app/pubspec.yaml')
old=p.read_text().strip()
m=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)\+(\d+)',old)
if not m: raise SystemExit('Unexpected VERSION format: '+old)
a,b,c,n=map(int,m.groups())
if kind=='major': a,b,c=a+1,0,0
elif kind=='minor':b,c=b+1,0
else:c+=1
new=f'{a}.{b}.{c}+{n+1}'
s=q.read_text()
s,count=re.subn(r'(?m)^version:\s*\S+\s*$',f'version: {new}',s,count=1)
if count!=1:raise SystemExit('Could not update app/pubspec.yaml version')
q.write_text(s)
p.write_text(new+'\n')
print(f'Version: {old} -> {new}')
TT_BUMPPY
version="$(cat VERSION)"
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  git add -- VERSION app/pubspec.yaml
else
  echo 'No commits yet: adding initial project scaffold with this first version bump.'
  git add -A
  git diff --cached --stat
fi
git commit -m "chore: bump TapTether to $version"
git push -u origin main
echo "Pushed version $version to github.com/ssnanda/taptether-source (main)"
