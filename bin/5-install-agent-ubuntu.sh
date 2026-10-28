#!/usr/bin/env bash
# Build and deploy the Ubuntu desktop agent over SSH.
# Usage: ./bin/5-install-agent-ubuntu.sh USER@HOST [--help]
#   USER@HOST      Required SSH destination for installation.
#   -h, --help     Show this help.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then sed -n "2,7p" "$0" | sed "s/^# //"; exit 0; fi
[[ $# -eq 1 ]] || { echo "Usage: ./bin/5-install-agent-ubuntu.sh USER@HOST" >&2; exit 2; }
HOST="${1:-}"
[[ "$HOST" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+$ ]] || {
  echo 'Usage: ./bin/5-install-agent-ubuntu.sh user@host' >&2; exit 2;
}
version="$(cat "$ROOT/VERSION")"
"$ROOT/bin/2b-tt-ubuntu.sh"
python3 "$ROOT/bin/9-tt-brand-icons.py"
arch="$(ssh "$HOST" 'dpkg --print-architecture')"
[[ "$arch" == amd64 || "$arch" == arm64 ]] || {
  echo "Unsupported remote Ubuntu architecture: $arch" >&2; exit 1;
}
package="$ROOT/dist/ubuntu/taptether-agent_${version}_${arch}.deb"
[[ -s "$package" ]] || { echo "Missing installer: $package" >&2; exit 1; }
stage="$(ssh "$HOST" 'mktemp -d /tmp/taptether-install.XXXXXXXX')"
[[ "$stage" =~ ^/tmp/taptether-install\.[a-zA-Z0-9]+$ ]] || {
  echo "Invalid remote temp directory: $stage" >&2; exit 1;
}
trap 'ssh "$HOST" "rm -rf '\''$stage'\''" >/dev/null 2>&1 || true' EXIT
scp "$package" "$ROOT/bin/4-ubuntu-desktop-setup.sh" "$ROOT/bin/7-tt-update-ubuntu.sh" "$ROOT/desktop/ubuntu/taptether_tray.py" "$ROOT/dist/branding/TapTether-icon.png" "$HOST:$stage/"
ssh -tt "$HOST" "set -e; dpkg-deb --info '$stage/$(basename "$package")' >/dev/null; sudo apt install -y '$stage/$(basename "$package")'; bash '$stage/4-ubuntu-desktop-setup.sh' install"
echo "TapTether $version deployed and enabled on $HOST. The installer above displayed PRIVATE pairing values."
