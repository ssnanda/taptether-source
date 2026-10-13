import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Trust-on-first-use SSH host keys, scoped to an exact LAN address and port.
/// Never silently overwrite a host key after the first authenticated connection.
class SshHostTrustStore {
  SshHostTrustStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _prefix = 'taptether.ssh.host-fingerprint.v1.';

  static String _storageKey(String host, int port) {
    final canonical = '${host.trim().toLowerCase()}:$port';
    return '$_prefix${sha256.convert(utf8.encode(canonical))}';
  }

  static bool validFingerprint(String value) =>
      RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(value);

  Future<String?> trustedFingerprint(String host, {int port = 22}) async {
    final value = await _storage.read(key: _storageKey(host, port));
    if (value != null && !validFingerprint(value)) {
      throw StateError('Saved SSH host identity is invalid. Refusing connection.');
    }
    return value;
  }

  /// Call only AFTER verified SSH user authentication has succeeded.
  /// A changed host identity is always blocked and never re-pinned automatically.
  Future<void> rememberAuthenticated(String host, String fingerprint,
      {int port = 22}) async {
    if (!validFingerprint(fingerprint)) {
      throw const FormatException('Unrecognized SSH server fingerprint.');
    }
    final key = _storageKey(host, port);
    final previous = await _storage.read(key: key);
    if (previous != null && previous != fingerprint) {
      throw StateError('SSH host identity changed. Connection blocked.');
    }
    if (previous == null) await _storage.write(key: key, value: fingerprint);
  }
}
