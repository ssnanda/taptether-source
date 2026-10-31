import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device-bound AES-256-GCM vault. The encryption key is protected by the OS
/// secure store, never synchronizes via iCloud and is excluded from backups.
class ResideoLocalVault {
  ResideoLocalVault({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.unlocked_this_device,
                synchronizable: false,
              ),
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            ),
        _legacy = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final FlutterSecureStorage _legacy;
  static const keyName = 'taptether.resideo.device-vault.v2.key';
  static const dataName = 'taptether.resideo.device-vault.v2.data';
  static const legacyPrefix = 'taptether.honeywellhome.v1.';
  static const _purpose = 'taptether-resideo-local-vault-v2';

  Future<Map<String, dynamic>?> read() async {
    final contents = await _storage.read(key: dataName);
    if (contents == null) {
      final old = <String, dynamic>{};
      for (final name in [
        'apiKey', 'apiSecret', 'accessToken', 'refreshToken', 'redirectUri',
      ]) {
        final value = await _legacy.read(key: '$legacyPrefix$name');
        if (value != null) {
          old[name] = value;
        }
      }
      if (old.isEmpty) {
        return null;
      }
      await write(old);
      for (final name in [
        'apiKey', 'apiSecret', 'accessToken', 'refreshToken', 'redirectUri',
      ]) {
        await _legacy.delete(key: '$legacyPrefix$name');
      }
      return old;
    }
    final keyText = await _storage.read(key: keyName);
    if (keyText == null) {
      throw const FormatException('Honeywell local vault key unavailable.');
    }
    try {
      final envelope = jsonDecode(contents);
      if (envelope is! Map || envelope['version'] != 2) {
        throw const FormatException('Unsupported local vault format.');
      }
      final keyBytes = base64Decode(keyText);
      final nonce = base64Decode(envelope['nonce'] as String);
      final ciphertext = base64Decode(envelope['ciphertext'] as String);
      final mac = base64Decode(envelope['mac'] as String);
      if (keyBytes.length != 32 || nonce.length != 12 || mac.length != 16) {
        throw const FormatException('Invalid local vault encoding.');
      }
      final key = SecretKey(keyBytes);
      try {
        final clear = await AesGcm.with256bits().decrypt(
          SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
          secretKey: key, aad: utf8.encode(_purpose),
        );
        final decoded = jsonDecode(utf8.decode(clear));
        if (decoded is! Map) {
          throw const FormatException('Invalid Honeywell vault contents.');
        }
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      } finally {
        key.destroy();
      }
    } catch (_) {
      throw const FormatException(
          'Could not decrypt Honeywell credentials on this device.');
    }
  }

  Future<void> write(Map<String, dynamic> values) async {
    var keyText = await _storage.read(key: keyName);
    if (keyText == null) {
      final random = Random.secure();
      keyText = base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
      await _storage.write(key: keyName, value: keyText);
    }
    final keyBytes = base64Decode(keyText);
    if (keyBytes.length != 32) {
      throw const FormatException('Invalid Honeywell device key.');
    }
    final key = SecretKey(keyBytes);
    try {
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(jsonEncode(values)),
        secretKey: key, aad: utf8.encode(_purpose),
      );
      await _storage.write(key: dataName, value: jsonEncode({
        'version': 2,
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      }));
    } finally {
      key.destroy();
    }
  }

  Future<void> clear() async {
    await _storage.delete(key: dataName);
    await _storage.delete(key: keyName);
    for (final name in [
      'apiKey', 'apiSecret', 'accessToken', 'refreshToken', 'redirectUri',
    ]) {
      await _legacy.delete(key: '$legacyPrefix$name');
    }
  }
}
