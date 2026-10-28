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

# Workmanager's iOS background engine requires iOS 14 or later.
podfile = root / 'app/ios/Podfile'
if podfile.is_file():
    # Normalize to exactly one active platform declaration. Flutter-generated
    # Podfiles may already specify iOS 15+; never prepend a duplicate.
    import re
    source = podfile.read_text()
    platform_pattern = re.compile(
        r"""^\s*platform\s+:ios\s*,\s*['"]([0-9]+(?:\.[0-9]+)?)['"].*$""",
        re.MULTILINE,
    )
    versions = [tuple(int(n) for n in m.group(1).split('.'))
                for m in platform_pattern.finditer(source)]
    minimum = (14, 0)
    selected = max([minimum, *versions])
    declaration = f"platform :ios, '{selected[0]}.{selected[1]}'"
    # Remove all active duplicates and insert one canonical declaration.
    source = platform_pattern.sub('', source).lstrip('\n')
    podfile.write_text(declaration + '\n' + source)
project = root / 'app/ios/Runner.xcodeproj/project.pbxproj'
if project.is_file():
    import re
    source = project.read_text()
    source = re.sub(r'IPHONEOS_DEPLOYMENT_TARGET = 1[0123]\.[0-9]+;',
                    'IPHONEOS_DEPLOYMENT_TARGET = 14.0;', source)
    project.write_text(source)
framework = root / 'app/ios/Flutter/AppFrameworkInfo.plist'
if framework.is_file():
    with framework.open('rb') as handle:
        details = plistlib.load(handle)
    details['MinimumOSVersion'] = '14.0'
    with framework.open('wb') as handle:
        plistlib.dump(details, handle, fmt=plistlib.FMT_XML)


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
