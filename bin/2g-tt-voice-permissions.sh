#!/usr/bin/env bash
# Apply microphone/speech permissions to Flutter's GENERATED native runners.
# Safe to rerun; neither credentials nor device identifiers are involved.
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

if ios.is_file():
    with ios.open('rb') as handle:
        info = plistlib.load(handle)
    info['NSMicrophoneUsageDescription'] = (
        'TapTether uses your microphone only when you tap Voice Search '
        'to dictate text for a paired TV.')
    info['NSSpeechRecognitionUsageDescription'] = (
        'TapTether converts your spoken search phrase to text after '
        'you start voice search.')
    with ios.open('wb') as handle:
        plistlib.dump(info, handle, fmt=plistlib.FMT_XML)
    print('Configured iOS microphone and speech privacy prompts')

if android.is_file():
    android_ns = 'http://schemas.android.com/apk/res/android'
    ET.register_namespace('android', android_ns)
    tree = ET.parse(android)
    manifest = tree.getroot()
    name_attr = '{' + android_ns + '}name'
    permission = 'android.permission.RECORD_AUDIO'
    if not any(tag.get(name_attr) == permission
               for tag in manifest.findall('uses-permission')):
        permission_tag = ET.Element('uses-permission')
        permission_tag.set(name_attr, permission)
        manifest.insert(0, permission_tag)
    queries = manifest.find('queries')
    if queries is None:
        queries = ET.Element('queries')
        first_application = manifest.find('application')
        if first_application is not None:
            manifest.insert(list(manifest).index(first_application), queries)
        else:
            manifest.append(queries)
    speech_action = 'android.speech.RecognitionService'
    found = any(action.get(name_attr) == speech_action
                for intent in queries.findall('intent')
                for action in intent.findall('action'))
    if not found:
        intent = ET.SubElement(queries, 'intent')
        action = ET.SubElement(intent, 'action')
        action.set(name_attr, speech_action)
    # Honeywell credentials must not be copied by Android cloud backup.
    # The local OS encryption key is device-bound and cannot be restored.
    application = manifest.find('application')
    if application is not None:
        application.set('{' + android_ns + '}allowBackup', 'false')
        application.set('{' + android_ns + '}fullBackupContent', 'false')
    tree.write(android, encoding='utf-8', xml_declaration=True)
    print('Configured Android speech and disabled app cloud backup')
PY
