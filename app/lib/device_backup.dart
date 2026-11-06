import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'resideo_local_vault.dart';

/// Portable, user-controlled encrypted pairing backup.
/// Nothing leaves this phone except via the user's explicitly selected file.
class DeviceBackupCodec {
  static const format = 'taptether-encrypted-devices';
  static const version = 1;
  static const iterations = 240000;
  static const maxFileBytes = 4 * 1024 * 1024;
  static const maxKeys = 150;
  static const unprotectedFormat = 'taptether-unprotected-devices';
  // Portable, authenticated backup payloads. Never export the Resideo
  // device-bound encryption key or raw vault ciphertext.
  static const resideoCredentialsKey = 'taptether.backup.resideo.credentials.v1';
  static const resideoLayoutKey = 'taptether.backup.resideo.layout.v1';
  static const goveeKey = 'taptether_govee_developer_key_v1';
  static const goveePlacementKey = 'taptether_govee_placements_v1';
  static const lumaKey = 'taptether_luma_nvr_v1';

  // Passwordless portable files deliberately have NO encryption. Only offer
  // this after an explicit confirmation: anyone with the .ttbackup file can
  // read pairing tokens, phone identity and SSH private keys.
  static Uint8List exportUnprotected(Map<String, String> raw) {
    final values = selectKeys(raw);
    if (values.isEmpty) {
      throw StateError('No saved devices to back up.');
    }
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
      'format': unprotectedFormat,
      'version': version,
      'createdUtc': DateTime.now().toUtc().toIso8601String(),
      'items': values,
    })));
    if (bytes.length > maxFileBytes) {
      throw const FormatException('Backup exceeds the allowed size.');
    }
    return bytes;
  }

  /// Try Keychain-stored backup passwords without prompting or exposing them.
  /// A failed match does not alter the encrypted file or return any secrets.
  /// Only the correct passphrase can authenticate an encrypted backup.
  static Future<Map<String, String>?> tryRestoreUsingSavedPasswords(
      List<int> bytes, Iterable<String?> passwords) async {
    if (!needsPassword(bytes)) {
      return restoreFile(bytes);
    }
    final attempted = <String>{};
    for (final password in passwords) {
      if (password == null || password.isEmpty ||
          !attempted.add(password)) {
        continue;
      }
      try {
        return await decrypt(bytes, password);
      } on FormatException {
        // Another saved password may be from a different backup generation.
      }
    }
    return null;
  }

  static bool needsPassword(List<int> bytes) {
    final payload = _envelope(bytes);
    if (payload['format'] == unprotectedFormat) {
      return false;
    }
    if (payload['format'] == format) {
      return true;
    }
    throw const FormatException('Unrecognized TapTether backup file.');
  }

  static Map<String, dynamic> _envelope(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxFileBytes) {
      throw const FormatException('Invalid backup file size.');
    }
    try {
      final payload = jsonDecode(utf8.decode(bytes));
      if (payload is Map<String, dynamic> &&
          payload['version'] == version) {
        return payload;
      }
    } catch (_) {
      // Omit error details that could contain private file data.
    }
    throw const FormatException('Invalid or unsupported backup file.');
  }

  static Future<Map<String, String>> restoreFile(
      List<int> bytes, {String? password}) async {
    if (needsPassword(bytes)) {
      if (password == null || password.isEmpty) {
        throw const FormatException('This backup needs its password.');
      }
      return decrypt(bytes, password);
    }
    final payload = _envelope(bytes);
    if (payload['format'] != unprotectedFormat ||
        payload['items'] is! Map) {
      throw const FormatException('Invalid unprotected backup file.');
    }
    final entries = payload['items'] as Map;
    if (entries.isEmpty || entries.length > maxKeys) {
      throw const FormatException('Invalid backup record count.');
    }
    final records = <String, String>{};
    for (final entry in entries.entries) {
      if (entry.key is! String || entry.value is! String ||
          !supportedKey(entry.key as String) ||
          (entry.key as String).length > 220 ||
          (entry.value as String).length > maxFileBytes) {
        throw const FormatException('Backup contains an invalid record.');
      }
      records[entry.key as String] = entry.value as String;
    }
    return records;
  }


  static bool supportedKey(String key) =>
      key == 'taptether.trusted.computers.v1' ||
      key == 'taptether.lg.webos.pairings.v1' ||
      key == 'taptether.samsung.tv.pairings.v1' ||
      key == 'taptether.xbox.consoles.v1' ||
      // ThinQ credentials are sensitive: protected automatic backups
      // encrypt them along with the rest of the saved pairing records.
      key == 'taptether.lg.thinq.pat.v1' ||
      key == 'taptether.lg.thinq.country.v1' ||
      key == 'taptether.lg.thinq.client-id.v1' ||
      key == 'taptether.lg.thinq.enabled.v1' ||
      key == 'taptether.lg.thinq.local-names.v1' ||
      key == goveeKey ||
      key == goveePlacementKey ||
      key == lumaKey ||
      key == resideoCredentialsKey ||
      key == resideoLayoutKey ||
      key == 'taptether.fridge.alerts.enabled.v1' ||
      key.startsWith('taptether.fridge.alerts.interval.v1.') ||
      key == 'taptether.device.ed25519.v1' ||
      key == 'taptether.network.locations.v1' ||
      key == 'taptether.appearance.theme.v1' ||
      key.startsWith('taptether.ssh.keys.') ||
      key == 'taptether.ssh.ed25519.private.v1' ||
      key.startsWith('taptether.ssh.host-fingerprint.v1.') ||
      key.startsWith('taptether.remote.layout.v1.');

  static Map<String, String> selectKeys(Map<String, String> all) {
    final entries = <String, String>{};
    for (final entry in all.entries) {
      if (!supportedKey(entry.key)) {
        continue;
      }
      if (entry.key.length > 220 || entry.value.length > maxFileBytes) {
        throw const FormatException('Saved device configuration is too large.');
      }
      entries[entry.key] = entry.value;
    }
    if (entries.length > maxKeys) {
      throw const FormatException('Too many stored backup entries.');
    }
    return entries;
  }

  /// Verify the actual saved bytes by decrypting every record.
  /// Never print or persist the decrypted data.
  static Future<void> verifyFile(
      List<int> bytes, Map<String, String> expected, {String? password}) async {
    final restored = await restoreFile(bytes, password: password);
    if (restored.length != expected.length ||
        restored.entries.any((entry) => expected[entry.key] != entry.value)) {
      throw const FormatException(
          'Backup verification failed: records do not match.');
    }
  }

  static Future<Uint8List> encrypt(
      Map<String, String> raw, String passphrase) async {
    if (passphrase.length < 12) {
      throw const FormatException(
          'Use a backup password of at least 12 characters.');
    }
    final values = selectKeys(raw);
    if (values.isEmpty) {
      throw StateError('No TapTether settings or pairings to back up.');
    }
    final plaintext = utf8.encode(jsonEncode({
      'schema': version,
      'createdUtc': DateTime.now().toUtc().toIso8601String(),
      'items': values,
    }));
    if (plaintext.length > maxFileBytes ~/ 2) {
      throw const FormatException('Backup exceeds the allowed size.');
    }
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final algorithm = AesGcm.with256bits();
    final nonce = algorithm.newNonce();
    final kdf = Pbkdf2(
        macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
    final secret = await kdf.deriveKeyFromPassword(
        password: passphrase, nonce: salt);
    try {
      final box = await algorithm.encrypt(plaintext, secretKey: secret,
          nonce: nonce, aad: utf8.encode(format));
      final file = utf8.encode(jsonEncode({
        'format': format,
        'version': version,
        'kdf': 'PBKDF2-HMAC-SHA256',
        'iterations': iterations,
        'salt': base64Encode(salt),
        'cipher': 'AES-256-GCM',
        'nonce': base64Encode(nonce),
        'mac': base64Encode(box.mac.bytes),
        'ciphertext': base64Encode(box.cipherText),
      }));
      if (file.length > maxFileBytes) {
        throw const FormatException('Encrypted backup is too large.');
      }
      return Uint8List.fromList(file);
    } finally {
      secret.destroy();
    }
  }

  static Future<Map<String, String>> decrypt(
      List<int> bytes, String passphrase) async {
    if (bytes.isEmpty || bytes.length > maxFileBytes) {
      throw const FormatException('Invalid backup file size.');
    }
    try {
      final envelope = jsonDecode(utf8.decode(bytes));
      if (envelope is! Map ||
          envelope['format'] != format ||
          envelope['version'] != version ||
          envelope['kdf'] != 'PBKDF2-HMAC-SHA256' ||
          envelope['cipher'] != 'AES-256-GCM' ||
          envelope['iterations'] != iterations) {
        throw const FormatException('Unsupported TapTether backup format.');
      }
      final salt = base64Decode(envelope['salt'] as String);
      final nonce = base64Decode(envelope['nonce'] as String);
      final mac = base64Decode(envelope['mac'] as String);
      final ciphertext = base64Decode(envelope['ciphertext'] as String);
      if (salt.length != 16 || nonce.length != 12 ||
          mac.length != 16 || ciphertext.isEmpty ||
          ciphertext.length > maxFileBytes) {
        throw const FormatException('Corrupted encrypted backup.');
      }
      final kdf = Pbkdf2(
          macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
      final secret = await kdf.deriveKeyFromPassword(
          password: passphrase, nonce: salt);
      List<int> plaintext;
      try {
        plaintext = await AesGcm.with256bits().decrypt(
          SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
          secretKey: secret, aad: utf8.encode(format));
      } finally {
        secret.destroy();
      }
      final payload = jsonDecode(utf8.decode(plaintext));
      if (payload is! Map || payload['schema'] != version ||
          payload['items'] is! Map) {
        throw const FormatException('Invalid decrypted backup.');
      }
      final raw = Map<String, dynamic>.from(payload['items'] as Map);
      if (raw.length > maxKeys || raw.isEmpty) {
        throw const FormatException('Invalid backup entry count.');
      }
      final validated = <String, String>{};
      for (final entry in raw.entries) {
        if (!supportedKey(entry.key) ||
            entry.key.length > 220 ||
            entry.value is! String ||
            (entry.value as String).length > maxFileBytes) {
          throw const FormatException('Unrecognized backup data.');
        }
        validated[entry.key] = entry.value as String;
      }
      return validated;
    } on SecretBoxAuthenticationError {
      throw const FormatException(
          'Incorrect backup password or altered backup file.');
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException(
          'Incorrect backup password or invalid backup file.');
    }
  }
}

/// Backs up ordinary Keychain values and decrypted, portable Resideo records.
/// The Resideo vault key, app PIN and biometrics are excluded from backups.
class DeviceBackupStore {
  DeviceBackupStore({
    FlutterSecureStorage? storage,
    FlutterSecureStorage? integrationStorage,
    ResideoLocalVault? resideoVault,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _integrationStorage = integrationStorage ??
            storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            ),
        _resideoVault = resideoVault ?? ResideoLocalVault(storage: storage);

  final FlutterSecureStorage _storage;
  final FlutterSecureStorage _integrationStorage;
  final ResideoLocalVault _resideoVault;

  static const _lgKeys = <String>[
    'taptether.lg.thinq.pat.v1',
    'taptether.lg.thinq.country.v1',
    'taptether.lg.thinq.client-id.v1',
    'taptether.lg.thinq.enabled.v1',
    'taptether.lg.thinq.local-names.v1',
    'taptether.fridge.alerts.enabled.v1',
  ];
  static const _otherKeys = <String>[
    DeviceBackupCodec.goveeKey,
    DeviceBackupCodec.goveePlacementKey,
    DeviceBackupCodec.lumaKey,
  ];

  static bool _usesBackgroundKeychain(String key) =>
      _lgKeys.contains(key) ||
      key.startsWith('taptether.fridge.alerts.interval.v1.');

  Future<Map<String, String>> snapshot() async {
    final values = await _storage.readAll();
    // Different Keychain accessibility is used by ThinQ and fridge alerts.
    for (final key in _lgKeys) {
      final value = await _integrationStorage.read(key: key);
      if (value != null) {
        values[key] = value;
      }
    }
    for (final key in _otherKeys) {
      final value = await _storage.read(key: key);
      if (value != null) {
        values[key] = value;
      }
    }
    final vault = await _resideoVault.read();
    if (vault != null && vault.isNotEmpty) {
      values[DeviceBackupCodec.resideoCredentialsKey] = jsonEncode(vault);
    }
    final layout = await _resideoVault.readLayout();
    if (layout != null && layout.isNotEmpty) {
      values[DeviceBackupCodec.resideoLayoutKey] = jsonEncode(layout);
    }
    return DeviceBackupCodec.selectKeys(values);
  }

  static Map<String, dynamic>? _vaultData(
      String? raw, {required bool credentials}) {
    if (raw == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded.isEmpty) {
        throw const FormatException('Invalid integration backup data.');
      }
      const allowed = <String>{
        'apiKey', 'apiSecret', 'accessToken',
        'refreshToken', 'redirectUri', 'expiresAtUtc',
      };
      final map = <String, dynamic>{};
      for (final pair in decoded.entries) {
        if (pair.key is! String ||
            (credentials &&
                (!allowed.contains(pair.key) || pair.value is! String))) {
          throw const FormatException('Invalid integration backup data.');
        }
        map[pair.key as String] = pair.value;
      }
      return map;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid integration backup data.');
    }
  }

  Future<int> restore(Map<String, String> entries) async {
    if (entries.isEmpty ||
        entries.length > DeviceBackupCodec.maxKeys ||
        entries.keys.any((key) => !DeviceBackupCodec.supportedKey(key))) {
      throw const FormatException('Invalid TapTether backup.');
    }
    // Reject malformed vault entries before changing any live credentials.
    final credentials = _vaultData(
        entries[DeviceBackupCodec.resideoCredentialsKey],
        credentials: true);
    final layout = _vaultData(
        entries[DeviceBackupCodec.resideoLayoutKey],
        credentials: false);
    final originals = await snapshot();
    final originalCredentials = await _resideoVault.read();
    final originalLayout = await _resideoVault.readLayout();
    final changed = <String>[];
    var vaultTouched = false;
    try {
      for (final entry in entries.entries) {
        if (entry.key == DeviceBackupCodec.resideoCredentialsKey ||
            entry.key == DeviceBackupCodec.resideoLayoutKey) {
          continue;
        }
        final target = _usesBackgroundKeychain(entry.key)
            ? _integrationStorage : _storage;
        await target.write(key: entry.key, value: entry.value);
        changed.add(entry.key);
      }
      if (credentials != null || layout != null) {
        vaultTouched = true;
      }
      if (credentials != null) {
        await _resideoVault.write(credentials);
      }
      if (layout != null) {
        await _resideoVault.writeLayout(layout);
      }
      return entries.length;
    } catch (_) {
      for (final key in changed.reversed) {
        final target =
            _usesBackgroundKeychain(key) ? _integrationStorage : _storage;
        try {
          if (originals.containsKey(key)) {
            await target.write(key: key, value: originals[key]);
          } else {
            await target.delete(key: key);
          }
        } catch (_) {
          // Keep original failure; rollback is best effort.
        }
      }
      if (vaultTouched) {
        try {
          if (originalCredentials == null) {
            await _resideoVault.clear();
          } else {
            await _resideoVault.write(originalCredentials);
          }
          if (originalLayout == null) {
            await _resideoVault.clearLayout();
          } else {
            await _resideoVault.writeLayout(originalLayout);
          }
        } catch (_) {
          // Keep original failure; rollback is best effort.
        }
      }
      rethrow;
    }
  }
}
