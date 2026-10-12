import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SavedSshKey {
  const SavedSshKey({
    required this.id, required this.name, required this.createdAt,
    required this.publicKey,
  });
  final String id;
  final String name;
  final DateTime createdAt;
  final String publicKey;
}

/// Private keys and metadata remain in OS secure storage.
/// Migrates the original single-key record without rotating its key.
class PhoneSshKeyStore {
  PhoneSshKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _legacyKey = 'taptether.ssh.ed25519.private.v1';
  static const _indexKey = 'taptether.ssh.keys.index.v2';
  static const _defaultKey = 'taptether.ssh.keys.default.v2';
  static const _pemPrefix = 'taptether.ssh.keys.pem.v2.';
  final FlutterSecureStorage _storage;

  static String _newId() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256))
        .map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _checkName(String name) {
    final value = name.trim();
    if (value.isEmpty || value.length > 60 ||
        value.contains(RegExp(r'[\x00-\x1F]'))) {
      throw const FormatException('Key name must be 1–60 characters.');
    }
    return value;
  }

  static OpenSSHEd25519KeyPair _parse(String pem, [String? passphrase]) {
    final keys = SSHKeyPair.fromPem(pem, passphrase);
    if (keys.length != 1 || keys.single is! OpenSSHEd25519KeyPair) {
      throw const FormatException('Only OpenSSH Ed25519 keys are supported.');
    }
    return keys.single as OpenSSHEd25519KeyPair;
  }

  Future<List<Map<String, dynamic>>> _index() async {
    final raw = await _storage.read(key: _indexKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('Invalid SSH key index');
    return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> _writeIndex(List<Map<String, dynamic>> items) =>
      _storage.write(key: _indexKey, value: jsonEncode(items));

  Future<void> _migrate() async {
    final original = await _storage.read(key: _legacyKey);
    if (original == null || original.isEmpty) return;
    final oldKey = _parse(original);
    final oldPublic = formatPublicKey(oldKey);
    final entries = await _index();
    for (final entry in entries) {
      final pem = await _storage.read(key: '$_pemPrefix${entry['id']}');
      if (pem != null && formatPublicKey(_parse(pem)) == oldPublic) {
        await _storage.delete(key: _legacyKey);
        return;
      }
    }
    final id = _newId();
    await _storage.write(key: '$_pemPrefix$id', value: original);
    entries.add({
      'id': id, 'name': 'Original SSH Key',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    await _writeIndex(entries);
    if ((await _storage.read(key: _defaultKey)) == null) {
      await _storage.write(key: _defaultKey, value: id);
    }
    await _storage.delete(key: _legacyKey);
  }

  Future<List<SavedSshKey>> listKeys() async {
    await _migrate();
    final result = <SavedSshKey>[];
    for (final entry in await _index()) {
      final id = entry['id'] as String;
      final pem = await _storage.read(key: '$_pemPrefix$id');
      if (pem == null) throw StateError('Missing private key for $id');
      result.add(SavedSshKey(
        id: id, name: entry['name'] as String,
        createdAt: DateTime.parse(entry['createdAt'] as String),
        publicKey: formatPublicKey(_parse(pem)),
      ));
    }
    return result;
  }

  Future<String?> selectedId() async {
    final entries = await listKeys();
    if (entries.isEmpty) return null;
    final selected = await _storage.read(key: _defaultKey);
    return entries.any((key) => key.id == selected) ? selected : entries.first.id;
  }

  Future<void> selectKey(String id) async {
    if (!(await listKeys()).any((key) => key.id == id)) {
      throw StateError('SSH key not found.');
    }
    await _storage.write(key: _defaultKey, value: id);
  }

  Future<bool> get exists async => (await selectedId()) != null;

  Future<OpenSSHEd25519KeyPair?> load({String? id}) async {
    final selected = id ?? await selectedId();
    if (selected == null) return null;
    if (!(await listKeys()).any((key) => key.id == selected)) {
      throw StateError('SSH key not found.');
    }
    final pem = await _storage.read(key: '$_pemPrefix$selected');
    return pem == null ? null : _parse(pem);
  }

  Future<SavedSshKey> _save(String name, OpenSSHEd25519KeyPair key) async {
    final checked = _checkName(name);
    await _migrate();
    final records = await _index();
    if (records.length >= 50) throw StateError('Maximum of 50 SSH keys reached.');
    final id = _newId();
    final date = DateTime.now().toUtc();
    await _storage.write(key: '$_pemPrefix$id', value: key.toPem());
    try {
      records.add({'id': id, 'name': checked, 'createdAt': date.toIso8601String()});
      await _writeIndex(records);
      if (records.length == 1) {
        await _storage.write(key: _defaultKey, value: id);
      }
    } catch (_) {
      // Preserve indexed private keys even if a secure-storage write fails.
      final indexed = (await _index()).any((entry) => entry['id'] == id);
      if (!indexed) await _storage.delete(key: '$_pemPrefix$id');
      rethrow;
    }
    return SavedSshKey(id: id, name: checked, createdAt: date,
      publicKey: formatPublicKey(key));
  }

  Future<SavedSshKey> generateNamed(String name) async {
    final checked = _checkName(name);
    final pair = await crypto.Ed25519().newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    final pub = (await pair.extractPublicKey()).bytes;
    if (seed.length != 32 || pub.length != 32) {
      throw StateError('Invalid Ed25519 key');
    }
    return _save(checked, OpenSSHEd25519KeyPair(
      Uint8List.fromList(pub), Uint8List.fromList([...seed, ...pub]),
      'taptether-mobile'));
  }

  Future<SavedSshKey> importNamed(String name, String pem,
      {String? passphrase}) async {
    if (pem.length > 1024 * 1024) {
      throw const FormatException('Key file exceeds 1 MB.');
    }
    final key = _parse(pem, passphrase);
    final line = formatPublicKey(key);
    if ((await listKeys()).any((stored) => stored.publicKey == line)) {
      throw StateError('Key already exists. Rename it instead.');
    }
    return _save(name, key);
  }

  Future<void> renameKey(String id, String name) async {
    await _migrate();
    final entries = await _index();
    final i = entries.indexWhere((entry) => entry['id'] == id);
    if (i < 0) throw StateError('SSH key not found.');
    entries[i]['name'] = _checkName(name);
    await _writeIndex(entries);
  }

  Future<void> deleteKey(String id) async {
    await _migrate();
    final entries = await _index();
    if (!entries.any((item) => item['id'] == id)) {
      throw StateError('SSH key not found.');
    }
    // Delete the secure private key before removing the list entry.
    // If this fails, the original indexed key remains accessible.
    await _storage.delete(key: '$_pemPrefix$id');
    entries.removeWhere((entry) => entry['id'] == id);
    await _writeIndex(entries);
    if ((await _storage.read(key: _defaultKey)) == id) {
      if (entries.isEmpty) {
        await _storage.delete(key: _defaultKey);
      } else {
        await _storage.write(key: _defaultKey,
          value: entries.first['id'] as String);
      }
    }
  }

  /// Explicitly exports an unencrypted private key; UI must warn the user.
  Future<String> exportPrivatePem(String id) async {
    if (!(await listKeys()).any((key) => key.id == id)) {
      throw StateError('SSH key not found.');
    }
    final pem = await _storage.read(key: '$_pemPrefix$id');
    if (pem == null) throw StateError('SSH private key missing.');
    return pem;
  }

  // Compatibility methods used by earlier SSH installer paths.
  Future<OpenSSHEd25519KeyPair> generateIfMissing() async =>
      await load() ?? await _generateFirst();

  Future<OpenSSHEd25519KeyPair> _generateFirst() async {
    final record = await generateNamed('TapTether SSH Key');
    return (await load(id: record.id))!;
  }

  Future<OpenSSHEd25519KeyPair> importPem(String pem,
      {String? passphrase}) async {
    final record = await importNamed('Imported SSH Key', pem, passphrase: passphrase);
    await selectKey(record.id);
    return (await load(id: record.id))!;
  }

  Future<String?> publicKeyLine({String? id}) async {
    final key = await load(id: id);
    return key == null ? null : formatPublicKey(key);
  }

  static String formatPublicKey(OpenSSHEd25519KeyPair key) =>
      'ssh-ed25519 ${base64Encode(key.toPublicKey().encode())} taptether-mobile';

  Future<List<SSHIdentity>> authenticationIdentities({String? id}) async {
    final key = await load(id: id);
    if (key == null) throw StateError('Create or import an SSH key first.');
    return <SSHIdentity>[key];
  }
}
