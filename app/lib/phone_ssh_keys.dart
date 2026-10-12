import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Separate from the phone's TapTether agent-auth key.
/// Only the public SSH key goes into Ubuntu authorized_keys.
/// The OpenSSH private key stays in iOS Keychain / Android secure storage.
class PhoneSshKeyStore {
  PhoneSshKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _storageKey = 'taptether.ssh.ed25519.private.v1';
  final FlutterSecureStorage _storage;

  Future<bool> get exists async =>
      (await _storage.read(key: _storageKey))?.isNotEmpty ?? false;

  Future<OpenSSHEd25519KeyPair?> load() async {
    final pem = await _storage.read(key: _storageKey);
    if (pem == null || pem.isEmpty) return null;
    final keys = SSHKeyPair.fromPem(pem);
    if (keys.length != 1 || keys.single is! OpenSSHEd25519KeyPair) {
      throw const FormatException('Stored SSH key is not Ed25519');
    }
    return keys.single as OpenSSHEd25519KeyPair;
  }

  /// Generate once. Never silently replace an already authorized key.
  Future<OpenSSHEd25519KeyPair> generateIfMissing() async {
    final old = await load();
    if (old != null) return old;
    final pair = await crypto.Ed25519().newKeyPair();
    final seed = await pair.extractPrivateKeyBytes();
    final pub = (await pair.extractPublicKey()).bytes;
    if (seed.length != 32 || pub.length != 32) {
      throw StateError('Invalid generated Ed25519 SSH key');
    }
    final key = OpenSSHEd25519KeyPair(
      Uint8List.fromList(pub),
      Uint8List.fromList([...seed, ...pub]),
      'taptether-mobile',
    );
    await _storage.write(key: _storageKey, value: key.toPem());
    return key;
  }

  /// Import a user-selected OpenSSH Ed25519 key. Encrypted files require
  /// their passphrase. The decrypted key is then protected in OS secure storage.
  Future<OpenSSHEd25519KeyPair> importPem(
      String pem, {String? passphrase}) async {
    if (pem.length > 1024 * 1024) {
      throw const FormatException('SSH private-key file is too large');
    }
    final keys = SSHKeyPair.fromPem(pem, passphrase);
    if (keys.length != 1 || keys.single is! OpenSSHEd25519KeyPair) {
      throw const FormatException(
          'Import one OpenSSH Ed25519 private key (.pem or id_ed25519)');
    }
    final key = keys.single as OpenSSHEd25519KeyPair;
    await _storage.write(key: _storageKey, value: key.toPem());
    return key;
  }

  Future<String?> publicKeyLine() async {
    final key = await load();
    return key == null ? null : formatPublicKey(key);
  }

  static String formatPublicKey(OpenSSHEd25519KeyPair key) =>
      'ssh-ed25519 ${base64Encode(key.toPublicKey().encode())} taptether-mobile';

  Future<List<SSHIdentity>> authenticationIdentities() async {
    final key = await load();
    if (key == null) {
      throw StateError('Generate or import an SSH key first');
    }
    return <SSHIdentity>[key];
  }
}
