import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/device_backup.dart';
import 'package:taptether/resideo_local_vault.dart';

void main() {
  const passphrase = 'backup-test-passphrase';

  test('integration credentials roundtrip to a fresh device vault', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'taptether.lg.thinq.pat.v1': 'test-lg',
      DeviceBackupCodec.goveeKey: 'test-govee',
      DeviceBackupCodec.goveePlacementKey: '{"lamp":{"room":"Office"}}',
      DeviceBackupCodec.lumaKey: '{"host":"recorder"}',
    });
    const sourceStorage = FlutterSecureStorage();
    final sourceVault = ResideoLocalVault(storage: sourceStorage);
    await sourceVault.write(<String, dynamic>{
      'apiKey': 'test-key',
      'apiSecret': 'test-secret',
      'refreshToken': 'test-refresh',
    });
    await sourceVault.writeLayout(<String, dynamic>{'order': <String>['home']});
    final source = DeviceBackupStore(
        storage: sourceStorage, resideoVault: sourceVault);
    final selected = await source.snapshot();
    expect(selected.containsKey(DeviceBackupCodec.resideoCredentialsKey), true);
    expect(selected.containsKey(ResideoLocalVault.keyName), false);
    expect(selected[DeviceBackupCodec.goveeKey], 'test-govee');
    final file = await DeviceBackupCodec.encrypt(selected, passphrase);
    await DeviceBackupCodec.verifyFile(file, selected, password: passphrase);

    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    const targetStorage = FlutterSecureStorage();
    final targetVault = ResideoLocalVault(storage: targetStorage);
    final target = DeviceBackupStore(
        storage: targetStorage, resideoVault: targetVault);
    final imported = await DeviceBackupCodec.restoreFile(
        file, password: passphrase);
    expect(await target.restore(imported), selected.length);
    expect(await target.snapshot(), selected);
    expect((await targetVault.read())?['apiKey'], 'test-key');
    expect((await targetVault.readLayout())?['order'], <String>['home']);
    expect(await targetStorage.read(key: DeviceBackupCodec.goveeKey),
        'test-govee');
  });

  test('a legacy backup without integration entries is still restorable', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final store = DeviceBackupStore(storage: const FlutterSecureStorage());
    final old = <String, String>{
      'taptether.trusted.computers.v1': '[{"name":"Mac"}]',
    };
    final file = await DeviceBackupCodec.encrypt(old, passphrase);
    final records = await DeviceBackupCodec.restoreFile(
        file, password: passphrase);
    await store.restore(records);
    expect((await store.snapshot())['taptether.trusted.computers.v1'],
        old['taptether.trusted.computers.v1']);
  });

  test('a mismatch causes verification to fail', () async {
    const selected = <String, String>{
      'taptether.trusted.computers.v1': 'value',
    };
    final file = await DeviceBackupCodec.encrypt(selected, passphrase);
    await expectLater(DeviceBackupCodec.verifyFile(
      file, <String, String>{'taptether.trusted.computers.v1': 'different'},
      password: passphrase,
    ), throwsFormatException);
  });
}
