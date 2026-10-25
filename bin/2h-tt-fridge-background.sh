#!/usr/bin/env bash
# Configure generated native runners for opt-in refrigerator notifications.
# iOS background tasks are OS scheduled and not guaranteed to run on time.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import pathlib
import plistlib
import sys
import xml.etree.ElementTree as ET

root = pathlib.Path(sys.argv[1])
ios = root / 'app/ios/Runner/Info.plist'
android = root / 'app/android/app/src/main/AndroidManifest.xml'
task_id = 'com.taptether.taptether.fridge-watch'
if ios.is_file():
    with ios.open('rb') as handle:
        info = plistlib.load(handle)
    modes = info.get('UIBackgroundModes') or []
    if 'fetch' not in modes:
        modes.append('fetch')
    info['UIBackgroundModes'] = modes
    identifiers = info.get('BGTaskSchedulerPermittedIdentifiers') or []
    if task_id not in identifiers:
        identifiers.append(task_id)
    info['BGTaskSchedulerPermittedIdentifiers'] = identifiers
    with ios.open('wb') as handle:
        plistlib.dump(info, handle, fmt=plistlib.FMT_XML)
    print('Configured iOS BGAppRefresh refrigerator checks')

if android.is_file():
    uri = 'http://schemas.android.com/apk/res/android'
    ET.register_namespace('android', uri)
    tree = ET.parse(android)
    manifest = tree.getroot()
    name = '{' + uri + '}name'
    for permission in ('android.permission.POST_NOTIFICATIONS',):
        if not any(tag.get(name) == permission for tag in
                   manifest.findall('uses-permission')):
            el = ET.Element('uses-permission')
            el.set(name, permission)
            manifest.insert(0, el)
    tree.write(android, encoding='utf-8', xml_declaration=True)
    print('Configured Android local notification permission')

# Local notifications require core library desugaring in the generated
# Android app even when we only show immediate notifications.
kts = root / 'app/android/app/build.gradle.kts'
groovy = root / 'app/android/app/build.gradle'
gradle = kts if kts.is_file() else groovy
if gradle.is_file():
    source = gradle.read_text()
    if 'isCoreLibraryDesugaringEnabled' not in source and kts.is_file():
        source = source.replace('compileOptions {',
                                'compileOptions {\n        isCoreLibraryDesugaringEnabled = true',
                                1)
    elif 'coreLibraryDesugaringEnabled' not in source and groovy.is_file():
        source = source.replace('compileOptions {',
                                'compileOptions {\n        coreLibraryDesugaringEnabled true',
                                1)
    if 'com.android.tools:desugar_jdk_libs:' not in source:
        line = ('coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")'
                if kts.is_file() else
                "coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'")
        source += '\ndependencies {\n    ' + line + '\n}\n'
    gradle.write_text(source)
    print('Configured Android notification desugaring')
PY
