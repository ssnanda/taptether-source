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

  test('preview lists Xbox and ThinQ names without exposing cloud secrets', () {
    final preview = BackupPreview.fromRecords({
      'taptether.xbox.consoles.v1':
          '[{"name":"Xbox Series X","certificateSha256":"SECRET_CERT"}]',
      'taptether.lg.thinq.enabled.v1':
          '[{"name":"Refrigerator","id":"SECRET_DEVICE_ID"}]',
      'taptether.lg.thinq.pat.v1': 'SECRET_LG_TOKEN',
    });
    expect(preview.deviceCount, 2);
    expect(preview.groups['Xbox consoles'], ['Xbox Series X']);
    expect(preview.groups['LG appliances'], ['Refrigerator']);
    expect(preview.otherRecordCount, 1);
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
