#!/usr/bin/env bash
# Integrate a real iOS WidgetKit extension into the generated Flutter project.
# Safe to rerun after flutter create; does not affect desktop agents or Android.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/app/ios"
RUNNER="$IOS/Runner/AppDelegate.swift"
test -f "$RUNNER" || { echo "Flutter iOS runner must exist first" >&2; exit 1; }
mkdir -p "$IOS/TapTetherControls"
cp "$ROOT/bin/ios/TapTetherControlsShared.swift" "$IOS/TapTetherControls/TapTetherControlsShared.swift"
cp "$ROOT/bin/ios/TapTetherLgRemoteNative.swift" "$IOS/TapTetherControls/TapTetherLgRemoteNative.swift"
cp "$ROOT/bin/ios/TapTetherControlWidgets.swift" "$IOS/TapTetherControls/TapTetherControlWidgets.swift"
if ! grep -q 'enum TapTetherSharedTV' "$RUNNER"; then
  printf '\n' >> "$RUNNER"
  cat "$ROOT/bin/ios/TapTetherControlsShared.swift" >> "$RUNNER"
  printf '\n' >> "$RUNNER"
  cat "$ROOT/bin/ios/TapTetherLgRemoteNative.swift" >> "$RUNNER"
  printf '\n' >> "$RUNNER"
  cat "$ROOT/bin/ios/TapTetherControlsRunner.swift" >> "$RUNNER"
fi
python3 - "$IOS" <<'PY'
import pathlib
import plistlib
import sys
ios = pathlib.Path(sys.argv[1])
group = 'group.com.taptether.taptether.controls'
runner_info = ios / 'Runner' / 'Info.plist'
with runner_info.open('rb') as handle:
    info = plistlib.load(handle)
info['NSSupportsLiveActivities'] = True
ats = info.setdefault('NSAppTransportSecurity', {})
ats['NSAllowsLocalNetworking'] = True
with runner_info.open('wb') as handle:
    plistlib.dump(info, handle, sort_keys=False)
widget = ios / 'TapTetherControls'
widget_info = {
    'CFBundleDevelopmentRegion': '$(DEVELOPMENT_LANGUAGE)',
    'CFBundleDisplayName': 'TapTether Controls',
    'CFBundleExecutable': '$(EXECUTABLE_NAME)',
    'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleInfoDictionaryVersion': '6.0',
    'CFBundleName': '$(PRODUCT_NAME)',
    'CFBundlePackageType': 'XPC!',
    'CFBundleShortVersionString': (ios.parents[1] / 'VERSION').read_text().strip().split('+')[0],
    'CFBundleVersion': (ios.parents[1] / 'VERSION').read_text().strip().split('+')[1],
    'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'},
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
}
for path, entries in (
    (widget / 'Info.plist', widget_info),
    (widget / 'TapTetherControls.entitlements',
     {'com.apple.security.application-groups': [group]}),
):
    with path.open('wb') as handle:
        plistlib.dump(entries, handle)
runner_entitlements = ios / 'Runner' / 'Runner.entitlements'
if runner_entitlements.exists():
    with runner_entitlements.open('rb') as handle:
        entitlements = plistlib.load(handle)
else:
    entitlements = {}
groups = entitlements.setdefault('com.apple.security.application-groups', [])
if group not in groups:
    groups.append(group)
with runner_entitlements.open('wb') as handle:
    plistlib.dump(entitlements, handle)
PY
TT_IOS="$IOS" ruby <<'RUBY'
require 'xcodeproj'
ios = ENV.fetch('TT_IOS')
project = Xcodeproj::Project.open(File.join(ios, 'Runner.xcodeproj'))
runner = project.targets.find { |target| target.name == 'Runner' }
raise 'Runner target missing' unless runner
extension = project.targets.find { |target| target.name == 'TapTetherControls' }
unless extension
  extension = project.new_target(:app_extension, 'TapTetherControls', :ios, '18.0')
  group = project.main_group.new_group('TapTetherControls', 'TapTetherControls')
  %w[TapTetherControlsShared.swift TapTetherLgRemoteNative.swift TapTetherControlWidgets.swift].each do |file|
    ref = group.new_file(file)
    extension.source_build_phase.add_file_reference(ref)
  end
  phase = runner.new_copy_files_build_phase('Embed TapTether Controls')
  phase.dst_subfolder_spec = '13'
  ref = phase.add_file_reference(extension.product_reference)
  ref.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
  runner.add_dependency(extension)
  # Flutter's Thin Binary reads Runner.app/Info.plist. Embedding the appex
  # after Thin Binary creates an Xcode dependency cycle; embed immediately
  # BEFORE Thin Binary (Flutter's documented phase order).
  runner.build_phases.delete(phase)
  thin = runner.build_phases.find { |item| item.display_name == 'Thin Binary' }
  raise 'Flutter Thin Binary phase missing' unless thin
  runner.build_phases.insert(runner.build_phases.index(thin), phase)
end
runner.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end
extension.build_configurations.each do |config|
  options = config.build_settings
  options['PRODUCT_NAME'] = '$(TARGET_NAME)'
  options['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.taptether.taptether.controls'
  options['INFOPLIST_FILE'] = 'TapTetherControls/Info.plist'
  options['GENERATE_INFOPLIST_FILE'] = 'NO'
  options['CODE_SIGN_ENTITLEMENTS'] = 'TapTetherControls/TapTetherControls.entitlements'
  options['SWIFT_VERSION'] = '5.0'
  options['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  options['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  options['TARGETED_DEVICE_FAMILY'] = '1'
  options['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
  options['SKIP_INSTALL'] = 'YES'
  options['CODE_SIGN_STYLE'] = 'Automatic'
  options['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
end
project.save
RUBY
echo "Staged TapTether iOS Control Center and Live Activity extension"
