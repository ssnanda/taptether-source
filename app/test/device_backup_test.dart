import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/device_backup.dart';

void main() {
  const password = 'correct-horse-battery-staple-2026';
  const records = <String, String>{
    'taptether.trusted.computers.v1': '[{"name":"Desktop"}]',
    'taptether.lg.webos.pairings.v1': '[{"name":"Family Room TV"}]',
    'taptether.samsung.tv.pairings.v1': '[{"name":"Office Samsung"}]',
    'taptether.device.ed25519.v1': '{"private":"secret","public":"key"}',
    'taptether.ssh.keys.pem.v2.mykey': 'sensitive-ssh-private-key',
    'taptether.network.locations.v1': '{"home":"ssid"}',
  };

  test('encrypted backup restores all supported pairings and phone identity',
      () async {
    final encrypted = await DeviceBackupCodec.encrypt(records, password);
    expect(utf8.decode(encrypted), isNot(contains('sensitive-ssh')));
    expect(utf8.decode(encrypted), isNot(contains('Family Room TV')));
    final decrypted = await DeviceBackupCodec.decrypt(encrypted, password);
    expect(decrypted, records);
  });

  test('protected files are recognized and restored with the password', () async {
    final encrypted = await DeviceBackupCodec.encrypt(records, password);
    expect(DeviceBackupCodec.needsPassword(encrypted), isTrue);
    expect(await DeviceBackupCodec.restoreFile(
        encrypted, password: password), records);
    await expectLater(DeviceBackupCodec.restoreFile(encrypted),
        throwsFormatException);
  });

  test('explicit unprotected files restore without a password', () async {
    final backup = DeviceBackupCodec.exportUnprotected(records);
    expect(DeviceBackupCodec.needsPassword(backup), isFalse);
    expect(await DeviceBackupCodec.restoreFile(backup), records);
    final tampered = jsonDecode(utf8.decode(backup)) as Map<String, dynamic>;
    tampered['items'] = {'unrelated.secret': 'should-never-restore'};
    await expectLater(
      DeviceBackupCodec.restoreFile(utf8.encode(jsonEncode(tampered))),
      throwsFormatException,
    );
  });

  test('backups use randomized salt and nonce', () async {
    final a = await DeviceBackupCodec.encrypt(records, password);
    final b = await DeviceBackupCodec.encrypt(records, password);
    expect(a, isNot(b));
  });

  test('reject incorrect password without returning keys', () async {
    final encrypted = await DeviceBackupCodec.encrypt(records, password);
    await expectLater(
      DeviceBackupCodec.decrypt(encrypted, 'wrong-but-long-passphrase'),
      throwsFormatException,
    );
  });

  test('detect encrypted data tampering before restore', () async {
    final encrypted = await DeviceBackupCodec.encrypt(records, password);
    final data = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
    final cipher = data['ciphertext'] as String;
    data['ciphertext'] = (cipher[0] == 'A' ? 'B' : 'A') + cipher.substring(1);
    await expectLater(
      DeviceBackupCodec.decrypt(utf8.encode(jsonEncode(data)), password),
      throwsFormatException,
    );
  });

  test('all real SSH private key records are included and auto password excluded', () {
    const values = <String, String>{
      'taptether.ssh.keys.index.v2': '[{"id":"k1","name":"Mac"}]',
      'taptether.ssh.keys.default.v2': 'k1',
      'taptether.ssh.keys.pem.v2.k1': '-----BEGIN OPENSSH PRIVATE KEY-----',
      'taptether.ssh.ed25519.private.v1': 'legacy-private-key',
      'taptether.ssh.host-fingerprint.v1.192.168.68.81':
          'trusted-server-identity',
      'taptether.auto-backup.password.v1': 'DO-NOT-EXPORT',
      'taptether.auto-backup.last-digest.v1': 'DO-NOT-EXPORT',
    };
    final records = DeviceBackupCodec.selectKeys(values);
    expect(records.length, 5);
    expect(records['taptether.ssh.keys.pem.v2.k1'], contains('PRIVATE KEY'));
    expect(records.containsKey('taptether.auto-backup.password.v1'), isFalse);
  });

  test('do not export app lock or arbitrary secure storage values', () {
    final chosen = DeviceBackupCodec.selectKeys({
      ...records,
      'taptether.lock.hash.v1': 'six-digit-pin-hash',
      'taptether.lock.bio.v1': 'true',
      'unrelated.password': 'someone-elses-credential',
    });
    expect(chosen.length, records.length);
    expect(chosen.containsKey('taptether.lock.hash.v1'), isFalse);
    expect(chosen.containsKey('unrelated.password'), isFalse);
  });

  test('require long passwords and reject unknown backup schema', () async {
    await expectLater(DeviceBackupCodec.encrypt(records, '123456'),
        throwsFormatException);
    final encrypted = await DeviceBackupCodec.encrypt(records, password);
    final changed = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
    changed['version'] = 2;
    await expectLater(
      DeviceBackupCodec.decrypt(utf8.encode(jsonEncode(changed)), password),
      throwsFormatException,
    );
  });
}
