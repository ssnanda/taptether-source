#!/usr/bin/env bash
# Move project-local extracted/review app bundles out of Spotlight's search
# scope after package validation. The installed canonical app is never touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || exit 0
CANONICAL="$HOME/Applications/TapTether Agent.app"

trash_bundle() {
  local bundle="$1" resolved canonical_resolved trash destination
  resolved="$(cd "$(dirname "$bundle")" && pwd -P)/$(basename "$bundle")"
  canonical_resolved="$(cd "$(dirname "$CANONICAL")" 2>/dev/null && pwd -P)/$(basename "$CANONICAL")" || canonical_resolved="$CANONICAL"
  [[ "$resolved" != "$canonical_resolved" ]] || {
    echo "Refusing to move canonical TapTether installation: $resolved" >&2
    return 1
  }
  if /usr/bin/osascript -e 'on run argv' \
      -e 'tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)' \
      -e 'end run' -- "$resolved" >/dev/null 2>&1; then
    echo "Moved temporary app to Trash: $resolved"
    return 0
  fi
  # Finder is unavailable on headless macOS CI. Moving to ~/.Trash still keeps
  # cleanup recoverable and prevents Spotlight from treating it as an app copy.
  trash="$HOME/.Trash"
  mkdir -p "$trash"
  destination="$trash/$(basename "$resolved").taptether-review.$$.$RANDOM"
  mv "$resolved" "$destination"
  echo "Moved temporary app to Trash fallback: $resolved"
}

while IFS= read -r -d '' bundle; do
  trash_bundle "$bundle"
done < <(find "$ROOT/dist" -type d -name '*.app' -print0 2>/dev/null)
