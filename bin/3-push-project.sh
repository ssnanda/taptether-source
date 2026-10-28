#!/usr/bin/env bash
# Commit and push staged/unstaged project files to TapTether source main.
# Usage: ./bin/3-push-project.sh [--help]
#   -h, --help     Show this help. Prompts before staging/pushing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then sed -n "2,6p" "$0" | sed "s/^# //"; exit 0; fi
[[ $# -eq 0 ]] || { echo "Unknown option: $1" >&2; sed -n "2,6p" "$0" >&2; exit 2; }
cd "$ROOT"
[[ "$(git branch --show-current)" == main ]] || { echo 'Switch to main branch first' >&2; exit 1; }
remote="$(git remote get-url origin 2>/dev/null || true)"
case "$remote" in
  git@github.com:ssnanda/taptether-source.git|ssh://git@github.com/ssnanda/taptether-source.git|https://github.com/ssnanda/taptether-source.git|https://github.com/ssnanda/taptether-source) ;;
  *) echo "Wrong origin: $remote" >&2;exit 1;;
esac
printf 'Stage ALL nonignored files and push to ssnanda/taptether-source? [y/N] '
read -r ans
[[ "$ans" == y || "$ans" == Y ]] || exit 0
git add -A
git diff --cached --stat
if git diff --cached --quiet; then echo 'No changes to commit.';else
  git commit -m "chore: update TapTether project"
fi
git push -u origin main
