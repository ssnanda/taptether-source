#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(git branch --show-current)" == main ]] || { echo 'Switch to main branch first' >&2; exit 1; }
remote="$(git remote get-url origin 2>/dev/null || true)"
case "$remote" in
  git@github.com:ssnanda/taptether.com.git|ssh://git@github.com/ssnanda/taptether.com.git|https://github.com/ssnanda/taptether.com.git|https://github.com/ssnanda/taptether.com) ;;
  *) echo "Wrong origin: $remote" >&2;exit 1;;
esac
printf 'Stage ALL nonignored files and push to ssnanda/taptether.com? [y/N] '
read -r ans
[[ "$ans" == y || "$ans" == Y ]] || exit 0
git add -A
git diff --cached --stat
if git diff --cached --quiet; then echo 'No changes to commit.';else
  git commit -m "chore: update TapTether project"
fi
git push -u origin main
