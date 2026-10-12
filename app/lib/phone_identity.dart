import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart' as hash;

/// Ed25519 private seed remains in platform secure storage, never on the agent.
/// This uses OS-protected storage; it is not a Secure Enclave non-exportable key.
class PhoneIdentity {
  PhoneIdentity._(this._private, this.publicKey, this.id);

  static const _storageKey = 'taptether.device.ed25519.v1';
  static const _storage = FlutterSecureStorage();
  final List<int> _private;
  final List<int> publicKey;
  final String id;

  String get encodedPublicKey => base64Encode(publicKey);

  static Future<PhoneIdentity> loadOrCreate() async {
    final previous = await _storage.read(key: _storageKey);
    if (previous != null && previous.isNotEmpty) {
      final obj = jsonDecode(previous);
      if (obj is! Map) throw const FormatException('Corrupt device key');
      final secret = base64Decode(obj['private'] as String);
      final public = base64Decode(obj['public'] as String);
      if (secret.length != 32 || public.length != 32) {
        throw const FormatException('Invalid saved key dimensions');
      }
      return PhoneIdentity._(secret, public,
          hash.sha256.convert(public).toString().substring(0, 32));
    }
    final pair = await Ed25519().newKeyPair();
    final private = await pair.extractPrivateKeyBytes();
    final public = (await pair.extractPublicKey()).bytes;
    await _storage.write(
      key: _storageKey,
      value: jsonEncode({'private': base64Encode(private),
        'public': base64Encode(public)}),
    );
    return PhoneIdentity._(private, public,
        hash.sha256.convert(public).toString().substring(0, 32));
  }

  Future<String> signChallenge(String nonce) async {
    final keyPair = SimpleKeyPairData(
      List<int>.of(_private),
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
    try {
      final message = utf8.encode('taptether-auth-v1\n$id\n$nonce');
      final signature = await Ed25519().sign(message, keyPair: keyPair);
      return base64Encode(signature.bytes);
    } finally {
      keyPair.destroy();
    }
  }
}
