#!/usr/bin/env python3
"""Render both approved TapTether artworks into launchers and release icons."""
from __future__ import annotations

import argparse
import plistlib
import xml.etree.ElementTree as ET
import base64
from io import BytesIO
import json
from pathlib import Path
import shutil
import subprocess
import sys

try:
    from PIL import Image
except ImportError as exc:
    raise SystemExit("Pillow is required to generate icons: python3 -m pip install Pillow") from exc

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
BRANDING = ROOT / "assets" / "branding"
DIST = ROOT / "dist" / "branding"

def read_art(filename: str) -> Image.Image:
    encoded = (BRANDING / filename).read_text(encoding="ascii").strip()
    blob = base64.b64decode(encoded, validate=True)
    return Image.open(BytesIO(blob)).convert("RGBA")

def png(image: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(path, "PNG", optimize=True)

def ios_icons(image: Image.Image) -> None:
    iconset = APP / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = iconset / "Contents.json"
    if not contents.exists():
        print("iOS runner not generated yet; run Flutter create and rerun icons.", file=sys.stderr)
        return
    data = json.loads(contents.read_text())
    count = 0
    for item in data.get("images", []):
        filename = item.get("filename")
        size_label = item.get("size")
        scale = item.get("scale", "1x")
        if not filename or not size_label:
            continue
        pixels = round(float(size_label.split("x")[0]) * float(scale.rstrip("x")))
        png(image, iconset / filename, pixels)
        count += 1
    if not count:
        raise SystemExit("iOS AppIcon asset catalog contains no image entries")
    print(f"iOS: generated {count} icons in Runner/AppIcon")

def android_icons(image: Image.Image) -> None:
    res = APP / "android/app/src/main/res"
    if not res.exists():
        print("Android runner not generated yet; run Flutter create and rerun icons.", file=sys.stderr)
        return
    for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                          ("xxhdpi", 144), ("xxxhdpi", 192)):
        png(image, res / f"mipmap-{density}/ic_launcher.png", size)
    print("Android: generated five mipmap launcher sizes")

def platform_network_permissions() -> None:
    # Flutter creates these native runner files during CI. Keep permissions
    # deterministic on Mac dev machines and clean GitHub runners.
    ios = APP / "ios/Runner/Info.plist"
    if ios.is_file():
        with ios.open("rb") as fh:
            info = plistlib.load(fh)
        info["NSLocalNetworkUsageDescription"] = (
            "TapTether searches your local Wi-Fi network for computers "
            "you choose to control."
        )
        info["CFBundleDisplayName"] = "TapTether"
        with ios.open("wb") as fh:
            plistlib.dump(info, fh)
        print("iOS: configured local network discovery permission")
    android = APP / "android/app/src/main/AndroidManifest.xml"
    if android.is_file():
        ET.register_namespace("android", "http://schemas.android.com/apk/res/android")
        tree = ET.parse(android)
        root = tree.getroot()
        android_name = "{http://schemas.android.com/apk/res/android}name"
        if not any(item.get(android_name) == "android.permission.INTERNET"
                   for item in root.findall("uses-permission")):
            perm = ET.Element("uses-permission")
            perm.set(android_name, "android.permission.INTERNET")
            root.insert(0, perm)
        application = root.find("application")
        if application is not None:
            application.set("{http://schemas.android.com/apk/res/android}label", "TapTether")
        tree.write(android, encoding="utf-8", xml_declaration=True)
        print("Android: configured LAN network permission")

def macos_icns(image: Image.Image) -> None:
    if sys.platform != "darwin" or not shutil.which("iconutil"):
        return
    iconset = DIST / "TapTether.iconset"
    for points in (16, 32, 128, 256, 512):
        png(image, iconset / f"icon_{points}x{points}.png", points)
        png(image, iconset / f"icon_{points}x{points}@2x.png", points * 2)
    subprocess.run(["iconutil", "-c", "icns", str(iconset),
                    "-o", str(DIST / "TapTether.icns")], check=True)
    print("macOS: generated native .icns for the desktop agent")

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true", help="Decode and validate artwork only")
    args = parser.parse_args()

    app_art = read_art("app-icon.webp.b64").convert("RGB")  # Apple requires opaque icons
    agent_art = read_art("agent-mark.png.b64")
    assert app_art.size[0] >= 192 and agent_art.size[0] >= 192
    if args.verify:
        print("Verified both approved app and transparent agent artworks")
        return
    DIST.mkdir(parents=True, exist_ok=True)
    # Publish browseable high-resolution PNG copies in the source repository.
    png(app_art, BRANDING / "TapTether-app.png", 1024)
    png(agent_art, BRANDING / "TapTether-agent.png", 1024)
    png(app_art, DIST / "TapTether-app.png", 1024)
    png(app_art, DIST / "TapTether-icon.png", 512)
    png(agent_art, DIST / "TapTether-mark.png", 512)
    png(app_art, APP / "assets/branding/taptether.png", 512)
    png(app_art, ROOT / "tv/lg-webos/icon.png", 80)
    png(app_art, ROOT / "tv/lg-webos/largeIcon.png", 130)
    ios_icons(app_art)
    android_icons(app_art)
    platform_network_permissions()
    macos_icns(app_art)
    print("Updated iOS, Android, LG webOS, AltStore, macOS and Ubuntu branding assets")

if __name__ == "__main__":
    main()
