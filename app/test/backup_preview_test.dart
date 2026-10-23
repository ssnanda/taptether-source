import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/backup_preview.dart';

void main() {
  test('preview shows device names, never credentials or fingerprints', () {
    final preview = BackupPreview.fromRecords({
      'taptether.trusted.computers.v1':
          '[{"name":"Studio Mac","token":"SECRET_TOKEN"}]',
      'taptether.lg.webos.pairings.v1':
          '[{"name":"Family Room TV","clientKey":"SECRET_LG"}]',
      'taptether.device.ed25519.v1': '{"private":"SECRET_SEED"}',
      'taptether.ssh.keys.pem.v2.key': 'SECRET_SSH_KEY',
    });
    expect(preview.recordCount, 4);
    expect(preview.deviceCount, 2);
    expect(preview.groups['Computers'], ['Studio Mac']);
    expect(preview.groups['LG TVs'], ['Family Room TV']);
    expect(preview.otherRecordCount, 2);
    expect(preview.groups.toString(), isNot(contains('SECRET_')));
  });

  test('invalid JSON cannot expose private backup records', () {
    final preview = BackupPreview.fromRecords({
      'taptether.trusted.computers.v1': 'SECRET_RAW_DATA',
    });
    expect(preview.groups['Computers'], isEmpty);
    expect(preview.groups.toString(), isNot(contains('SECRET_RAW_DATA')));
  });
}
