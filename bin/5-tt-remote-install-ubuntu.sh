#!/usr/bin/env bash
# Build current TapTether agent, copy, validate, install and configure over SSH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-sandip@192.168.68.87}"
[[ "$HOST" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+$ ]] || { echo 'Usage: ./bin/5-tt-remote-install-ubuntu.sh user@host' >&2; exit 2; }
version="$(cat "$ROOT/VERSION")"
"$ROOT/bin/2b-tt-ubuntu.sh"
arch="$(ssh "$HOST" 'dpkg --print-architecture')"
[[ "$arch" == amd64 || "$arch" == arm64 ]] || { echo "Unsupported remote Ubuntu architecture: $arch" >&2; exit 1; }
package="$ROOT/dist/ubuntu/taptether-agent_${version}_${arch}.deb"
[[ -s "$package" ]] || { echo "Missing installer: $package" >&2; exit 1; }
stage="$(ssh "$HOST" 'mktemp -d /tmp/taptether-install.XXXXXXXX')"
[[ "$stage" =~ ^/tmp/taptether-install\.[a-zA-Z0-9]+$ ]] || { echo "Invalid remote temp directory: $stage" >&2; exit 1; }
scp "$package" "$ROOT/bin/4-ubuntu-desktop-setup.sh" "$HOST:$stage/"
ssh -tt "$HOST" "set -e; dpkg-deb --info '$stage/$(basename "$package")' >/dev/null; sudo apt install -y '$stage/$(basename "$package")'; bash '$stage/4-ubuntu-desktop-setup.sh' install; rm -rf '$stage'; ~/.local/bin/taptetherctl status"
echo "TapTether $version deployed to $HOST. If /dev/uinput group was added, log out of the Ubuntu desktop and log back in (or reboot)."
