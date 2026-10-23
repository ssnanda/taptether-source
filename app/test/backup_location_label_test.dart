import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/backup_location_label.dart';

void main() {
  test('hides raw iOS iCloud Drive provider paths', () {
    expect(backupLocationLabel(
      automaticFolder: 'Files / com~apple~CloudDocs',
      manualPath: '/private/var/mobile/Library/Mobile Documents/'
          'com~apple~CloudDocs/TapTether-Devices-2026-10-23.ttbackup',
    ), 'iCloud Drive');
  });
  test('shows helpful iCloud Drive subfolders only', () {
    expect(backupLocationLabel(
      manualPath: '/private/var/mobile/Library/Mobile Documents/'
          'com~apple~CloudDocs/TapTether/Backups/my.ttbackup',
    ), 'iCloud Drive / TapTether / Backups');
  });
  test('shows selected Files folder without leaking provider IDs', () {
    expect(backupLocationLabel(automaticFolder: 'Files / My Backups'),
        'Files / My Backups');
    expect(backupLocationLabel(automaticFolder: 'Files / opaque~provider'),
        'Files');
    expect(backupLocationLabel(manualPath: '/private/var/mobile/tmp/foo.ttbackup'),
        'Files');
    expect(backupLocationLabel(), 'Choose a folder');
  });
}
