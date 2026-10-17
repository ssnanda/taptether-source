#!/usr/bin/env bash
# Fixed privileged Ubuntu updater. Only the owner-approved systemd unit calls
# this script. The TapTether agent cannot inject commands, paths or URLs.
set -euo pipefail
[[ "$(id -u)" == 0 ]] || { echo 'Root-only update helper' >&2; exit 1; }
owner="${TAPTETHER_OWNER:-}"
home="${TAPTETHER_HOME:-}"
[[ "$owner" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ && "$home" == /* &&
  "$home" != *$'\n'* ]] || { echo 'Invalid configured desktop owner' >&2; exit 1; }
actual_home="$(getent passwd "$owner" | cut -d: -f6)"
[[ "$actual_home" == "$home" ]] || { echo 'Configured user home changed' >&2; exit 1; }
arch="$(dpkg --print-architecture)"
[[ "$arch" == amd64 || "$arch" == arm64 ]] ||
  { echo 'Unsupported Ubuntu architecture' >&2; exit 1; }
current="$(/usr/local/bin/taptether-agent --version)"
info="$(python3 - "$arch" "$current" <<'PY'
import json, re, sys, urllib.request
arch, current = sys.argv[1:]
valid = re.compile(r'^(\d+)\.(\d+)\.(\d+)\+(\d+)$')
def parse(text):
    match = valid.fullmatch(text)
    if not match:
        raise SystemExit('Cannot compare agent versions.')
    return tuple(int(part) for part in match.groups())
request = urllib.request.Request(
    'https://api.github.com/repos/ssnanda/taptether.com/releases/tags/current',
    headers={'Accept':'application/vnd.github+json',
             'User-Agent':'TapTether-Ubuntu-Trusted-Updater'})
with urllib.request.urlopen(request, timeout=15) as response:
    release = json.load(response)
found = re.search(r'(\d+\.\d+\.\d+\+\d+)', release.get('name',''))
if not found:
    raise SystemExit('Release version unavailable.')
latest = found.group(1)
newer = parse(latest) > parse(current)
name = f'TapTetherAgent-Ubuntu-{arch}.deb'
matches = [a for a in release.get('assets', []) if a.get('name') == name]
if len(matches) != 1:
    raise SystemExit('Release package unavailable.')
asset = matches[0]
digest = asset.get('digest', '')
if not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', digest):
    raise SystemExit('Release SHA-256 digest missing.')
url = f'https://github.com/ssnanda/taptether.com/releases/download/current/{name}'
if asset.get('browser_download_url') != url:
    raise SystemExit('Unexpected release URL.')
print('\t'.join([latest,'yes' if newer else 'no',digest[7:].lower(),url]))
PY
)"
IFS=$'\t' read -r latest newer digest url <<<"$info"
if [[ "$newer" != yes ]]; then
  echo "TapTether already current: $current"
  exit 0
fi
tmp="$(mktemp -d /tmp/taptether-update.XXXXXXXX)"
chmod 0700 "$tmp"
trap 'rm -rf -- "$tmp"' EXIT
package="$tmp/taptether.deb"
curl --fail --location --silent --show-error --proto '=https'   --proto-redir '=https' --connect-timeout 12 --max-time 180 "$url"   -o "$package"
printf '%s  %s\n' "$digest" "$package" | sha256sum --check --status ||
  { echo 'Update SHA-256 mismatch' >&2; exit 1; }
[[ "$(dpkg-deb --field "$package" Package)" == taptether-agent &&
   "$(dpkg-deb --field "$package" Version)" == "$latest" &&
   "$(dpkg-deb --field "$package" Architecture)" == "$arch" ]] ||
  { echo 'Downloaded package identity mismatch' >&2; exit 1; }
# dpkg reads the root-only staging directory. apt's _apt sandbox cannot.
DEBIAN_FRONTEND=noninteractive dpkg --install "$package"
bundle=/usr/share/taptether
group="$(id -gn "$owner")"
for row in \
  "4-ubuntu-desktop-setup.sh|taptetherctl|0700" \
  "7-tt-update-ubuntu.sh|taptether-agent-update|0700"; do
  IFS='|' read -r source target mode <<<"$row"
  [[ -f "$bundle/$source" ]] || exit 1
  install -D -o "$owner" -g "$group" -m "$mode" \
    "$bundle/$source" "$home/.local/bin/$target"
done
install -D -o "$owner" -g "$group" -m 0755 \
  "$bundle/taptether_tray.py" \
  "$home/.local/share/taptether/taptether_tray.py"
install -D -o "$owner" -g "$group" -m 0644 \
  "$bundle/TapTether-icon.png" \
  "$home/.local/share/icons/hicolor/512x512/apps/taptether.png"
# Carry the new screen helper forward on ordinary user-approved upgrades,
# without replacing any input or screen permission state.
screen="$bundle/taptether_screen.py"
if [[ -s "$screen" ]]; then
  autostart="$home/.config/autostart/taptether-screen.desktop"
  install -d -o "$owner" -g "$group" -m 0755 "$(dirname "$autostart")"
  cat >"$tmp/taptether-screen.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=TapTether Screen Helper
Comment=On-demand private screen capture for the logged-in Ubuntu desktop
Exec=/usr/bin/python3 /usr/share/taptether/taptether_screen.py
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
  install -o "$owner" -g "$group" -m 0644 \
    "$tmp/taptether-screen.desktop" "$autostart"
  # Installing optional graphics packages is safe only outside dpkg; a failure
  # must not break the agent's existing keyboard, pairing or input paths.
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3-gi python3-pil gir1.2-gstreamer-1.0 \
    gir1.2-gst-plugins-base-1.0 gstreamer1.0-plugins-good \
    gstreamer1.0-pipewire xdg-desktop-portal >/dev/null 2>&1 || \
    echo 'TapTether screen dependencies need manual installation.' >&2
fi
# Install the refreshed root helper for the next user-approved update.
install -D -m 0755 "$bundle/9-tt-system-update-ubuntu.sh" \
  /usr/local/libexec/taptether-update-ubuntu.sh
# Update-in-place also applies new per-agent defaults. This root-only, fixed
# helper is invoked by the computer owner's installed systemd update service,
# never by an arbitrary mobile command. A local opt-out marker remains intact.
policy="/etc/polkit-1/rules.d/80-taptether-shutdown.rules"
dropin="/etc/systemd/system/taptether-agent.service.d/40-shutdown.conf"
install -d -m 0755 "$(dirname "$policy")" "$(dirname "$dropin")"
cat >"$tmp/power.rules" <<POLKIT
polkit.addRule(function(action, subject) {
  if ((action.id === "org.freedesktop.login1.power-off" ||
       action.id === "org.freedesktop.login1.power-off-multiple-sessions") &&
      subject.user === "$owner" && subject.isInGroup("taptether")) {
    return polkit.Result.YES;
  }
});
POLKIT
install -m 0644 "$tmp/power.rules" "$policy"
printf '[Service]\\nEnvironment=TAPTETHER_ENABLE_SHUTDOWN=1\\n' \
  >"$tmp/power.conf"
install -m 0644 "$tmp/power.conf" "$dropin"
systemctl daemon-reload
systemctl restart taptether-agent.service
systemctl is-active --quiet taptether-agent.service
echo "TapTether agent upgraded and restarted to $latest"
