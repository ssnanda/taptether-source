#!/usr/bin/env python3
"""Generate an AltStore source from a completed IPA. Never guess version or size."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import shutil
from zipfile import ZipFile

OWNER = "ssnanda"
REPO = "taptether.com"
TAG = "current"
BASE = f"https://github.com/{OWNER}/{REPO}/releases/download/{TAG}"
IOS_BUNDLE_ID = "com.itspector.taptether"
CONTROLS_BUNDLE_ID = "com.itspector.taptether.controls"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--version-file", default="VERSION")
    parser.add_argument("--output", default="altstore.json")
    parser.add_argument("--icon-output", default="dist/release/TapTether-icon.png")
    args = parser.parse_args()
    ipa = Path(args.ipa)
    if not ipa.is_file() or ipa.stat().st_size < 1000:
        parser.error(f"IPA is missing or too small: {ipa}")
    with ZipFile(ipa) as archive:
        candidates = [name for name in archive.namelist() if name.startswith("Payload/") and name.endswith(".app/Info.plist") and name.count("/") == 2]
        if len(candidates) != 1:
            parser.error("IPA must contain exactly one Payload/*.app/Info.plist")
        info = plistlib.loads(archive.read(candidates[0]))
        extensions = [name for name in archive.namelist()
                      if name.startswith("Payload/") and name.endswith(".appex/Info.plist")]
        if len(extensions) != 1:
            parser.error("IPA must contain exactly one iOS Controls extension")
        extension_info = plistlib.loads(archive.read(extensions[0]))
    bundle = info.get("CFBundleIdentifier")
    actual_version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    min_os = str(info.get("MinimumOSVersion", "13.0"))
    version = Path(args.version_file).read_text().strip()
    if "+" not in version or (actual_version, build) != tuple(version.split("+", 1)):
        parser.error(f"IPA version {actual_version}+{build} does not match VERSION {version}; rebuild the IPA")
    if bundle != IOS_BUNDLE_ID:
        parser.error(f"Unexpected iOS app bundle identifier: {bundle!r} (expected {IOS_BUNDLE_ID})")
    if extension_info.get("CFBundleIdentifier") != CONTROLS_BUNDLE_ID:
        parser.error(f"Unexpected iOS controls bundle identifier: {extension_info.get('CFBundleIdentifier')!r}")
    now = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    url = BASE + "/TapTether.ipa"
    release = {
        "version": actual_version,
        "buildVersion": build,
        "date": now,
        "localizedDescription": f"TapTether {version}: current iPhone build",
        "downloadURL": url,
        "size": ipa.stat().st_size,
        "minOSVersion": min_os,
    }
    app = {
        "name": "TapTether",
        "bundleIdentifier": bundle,
        "developerName": "ITSpector LLC",
        "subtitle": "Your devices. Your control. Your network.",
        "localizedDescription": "A privacy-first local-network keyboard, trackpad and system volume remote for your own devices.",
        "iconURL": BASE + "/TapTether-icon.png",
        "tintColor": "173A3C",
        "screenshotURLs": [],
        "version": actual_version,
        "buildVersion": build,
        "versionDate": now,
        "versionDescription": release["localizedDescription"],
        "downloadURL": url,
        "size": release["size"],
        "versions": [release],
    }
    source = {
        "name": "TapTether",
        "identifier": "com.taptether.altstore",
        "sourceURL": f"https://raw.githubusercontent.com/{OWNER}/{REPO}/main/altstore.json",
        "website": "https://taptether.com",
        "apps": [app],
        "news": [],
    }
    output = Path(args.output)
    output.write_text(json.dumps(source, indent=2) + "\n", encoding="utf-8")
    icon = Path(args.icon_output)
    icon.parent.mkdir(parents=True, exist_ok=True)
    source_icon = Path(__file__).resolve().parent.parent / 'dist' / 'branding' / 'TapTether-icon.png'
    if not source_icon.is_file():
        raise SystemExit('Brand icon missing. Run bin/9-tt-brand-icons.py before publication.')
    shutil.copyfile(source_icon, icon)
    print(f"Validated IPA {bundle} {version} ({ipa.stat().st_size:,} bytes)")
    print(f"Generated {output} and {icon}")

if __name__ == "__main__":
    main()
