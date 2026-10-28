#!/usr/bin/env bash
# Build, sign, and install TapTether on a USB-connected iPhone.
# Usage: ./bin/3-install-iphone.sh [--list-devices|list-devices] [--device ID] [--no-launch] [--dry-run] [--help]
#   --list-devices, list-devices  List detected eligible USB iPhones.
#   --device ID                  Select one detected device.
#   --no-launch                  Install without launching the app.
#   --dry-run                    Validate device without building/installing.
#   -h, --help                   Show this help.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_ID=''
LIST=0
NO_LAUNCH=0
DRY_RUN=0
LOG=''
banner(){ printf '\n========== %s ==========\n' "$1"; }
die(){ banner FAILED >&2; echo "$*" >&2; [[ -z "$LOG" ]] || echo "Build log: $LOG" >&2; exit 1; }
usage(){
cat <<'HELP'
Usage: ./bin/3-install-iphone.sh [list-devices|--list-devices] [--device ID] [--no-launch] [--dry-run] [--help]
Install a signed Debug build on a paired, USB-connected physical iPhone.
Configure Xcode > Settings > Accounts and Runner > Signing & Capabilities first.
HELP
}
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --list-devices|list-devices) LIST=1; shift ;;
    --no-launch) NO_LAUNCH=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --device) if [[ $# -lt 2 ]]; then echo 'Missing value for --device' >&2; usage >&2; exit 2; fi; DEVICE_ID="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$(uname)" == Darwin ]] || die 'A Mac with Xcode is required.'
for tool in xcodebuild xcrun python3 flutter; do command -v "$tool" >/dev/null || die "Missing $tool"; done
xcodebuild -version >/dev/null 2>&1 || die 'Select full Xcode with xcode-select.'
xcrun --find devicectl >/dev/null 2>&1 || die 'devicectl requires modern Xcode.'
banner 'CHECKING DEVICE'
device_json="$(mktemp)"
trap 'rm -f "$device_json"' EXIT
xcrun devicectl list devices --json-output "$device_json" >/dev/null || die 'Cannot list devices; unlock iPhone, trust Mac, and confirm pairing in Xcode.'
# CoreDevice reports USB transport as wired; exclude network-only devices and simulators.
device_rows="$(python3 - "$device_json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
for d in j.get("result",{}).get("devices",[]):
    h=d.get("hardwareProperties") or {}
    p=d.get("deviceProperties") or {}
    c=d.get("connectionProperties") or {}
    family=str(h.get("deviceFamily") or p.get("deviceFamily") or "")
    model=str(h.get("marketingName") or h.get("productType") or "")
    name=str(d.get("name") or p.get("name") or "")
    if 'iphone' not in (family+" "+model+" "+name).lower(): continue
    transport=str(c.get("transportType") or "").lower()
    if transport not in ("wired","usb"): continue
    device_id=str(d.get("identifier") or "")
    if not device_id: continue
    state=str(d.get("state") or p.get("state") or p.get("connectionState") or "not-reported")
    print("\t".join([device_id,name or model,state]))
PY
)"
if (( LIST )); then
  if [[ -n "$device_rows" ]]; then printf '%s\n' "$device_rows"; else
    echo 'No wired iPhones detected. CoreDevice currently reports:'
    xcrun devicectl list devices || true
  fi
  exit 0
fi
if [[ -z "$device_rows" ]]; then
  echo 'No eligible wired iPhone was found. CoreDevice reports:' >&2
  xcrun devicectl list devices >&2 || true
  die 'Check connection in Xcode > Window > Devices and Simulators. Run ./bin/3-install-iphone.sh --list-devices to retry.'
fi
matches="$(printf '%s\n' "$device_rows" | awk -F '\t' -v id="$DEVICE_ID" 'id=="" || $1==id')"
[[ -n "$matches" ]] || die 'Requested device was not found over USB.'
[[ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" == 1 ]] || die 'Multiple USB iPhones: use --list-devices and --device ID.'
chosen="$(printf '%s\n' "$matches" | head -n1)"
DEVICE_ID="$(printf '%s\n' "$chosen" | cut -f1)"
DEVICE_NAME="$(printf '%s\n' "$chosen" | cut -f2)"
state="$(printf '%s\n' "$chosen" | cut -f3)"
# CoreDevice on current Xcode releases commonly omits the top-level state.
# Confirm availability with an actual device query instead of rejecting an absent field.
case "$state" in
  connected|available|ready|not-reported) ;;
  disconnected|unavailable|not-paired|unpaired) die "iPhone reports state: $state. Unlock, trust Mac, and reconnect." ;;
  *) echo "Device reports state '$state'; verifying with CoreDevice..." ;;
esac
if ! xcrun devicectl device info details --device "$DEVICE_ID" >/dev/null 2>&1; then
  die "CoreDevice cannot query $DEVICE_NAME ($DEVICE_ID). Check USB cable, pairing, trust, Developer Mode, and that the phone is unlocked."
fi
echo "Device: $DEVICE_NAME ($DEVICE_ID)"
[[ -f "$ROOT/app/pubspec.yaml" ]] || die 'Flutter app/pubspec.yaml not found.'
command -v plutil >/dev/null || die 'plutil not found.'
if (( DRY_RUN )); then
  echo 'DRY RUN: no Flutter project generation, build, signing, or installation.'
  [[ -d "$ROOT/app/ios" ]] && echo 'iOS project exists.' || echo 'Flutter iOS project will be generated if missing.'
  exit 0
fi
cd "$ROOT/app"
# Flutter-generated iOS runner is not stored in this repo; generate when absent.
if [[ ! -d ios/Runner.xcodeproj ]]; then
  flutter create --platforms=ios --org com.taptether --project-name taptether .
fi
[[ -d ios/Runner.xcodeproj ]] || die 'Flutter did not create an iOS Xcode project.'
[[ -d ios/Runner.xcworkspace ]] || die 'iOS Xcode workspace missing; run flutter pub get.'
# Stage existing TapTether native iOS features just like the release workflow.
flutter pub get
bash "$ROOT/bin/2f-tt-ios-cloud-backup.sh"
bash "$ROOT/bin/2g-tt-voice-permissions.sh"
bash "$ROOT/bin/2h-tt-fridge-background.sh"
python3 "$ROOT/bin/9-tt-brand-icons.py"
banner BUILDING
LOG="$ROOT/app/build/iphone-install-build.log"
mkdir -p "$ROOT/app/build"
echo "Build log: $LOG"
banner SIGNING
if ! flutter build ios --debug >"$LOG" 2>&1; then
  tail -n 35 "$LOG" >&2 || true
  die 'Build/signing failed. Open ios/Runner.xcworkspace in Xcode, select Runner > Signing & Capabilities, choose your configured Team, and enable Automatic Signing. Complete any Apple account prompt in Xcode; this script will not retry authentication.'
fi
APP="$ROOT/app/build/ios/iphoneos/Runner.app"
[[ -d "$APP" ]] || die "Signed app not found at $APP"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null || true)"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print CFBundleDisplayName' "$APP/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print CFBundleName' "$APP/Info.plist" 2>/dev/null || echo Runner)"
[[ -n "$BUNDLE_ID" ]] || die 'Missing bundle identifier in built app.'
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || die 'App is not signed correctly.'
printf 'App: %s\nBundle identifier: %s\nBuild: Debug (signed)\n' "$APP_NAME" "$BUNDLE_ID"
banner INSTALLING
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" || die 'Install failed. Unlock phone, trust Mac and confirm Developer Mode, signing team, and provisioning.'
if (( ! NO_LAUNCH )); then
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" || die 'Installed successfully, but launch failed. Check device trust and permissions.'
fi
banner 'INSTALLATION COMPLETE'
echo "$APP_NAME ($BUNDLE_ID) installed on $DEVICE_NAME."
echo "Build log: $LOG"
