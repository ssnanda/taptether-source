import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/phone_ssh_keys.dart';

void main() {
  test('generated Ed25519 key survives OpenSSH private-key encoding', () async {
    final generated = await crypto.Ed25519().newKeyPair();
    final seed = await generated.extractPrivateKeyBytes();
    final public = (await generated.extractPublicKey()).bytes;
    expect(seed, hasLength(32));
    expect(public, hasLength(32));
    final key = OpenSSHEd25519KeyPair(
      Uint8List.fromList(public),
      Uint8List.fromList([...seed, ...public]),
      'taptether-mobile',
    );
    final pem = key.toPem();
    expect(pem, contains('BEGIN OPENSSH PRIVATE KEY'));
    final parsed = SSHKeyPair.fromPem(pem);
    expect(parsed, hasLength(1));
    expect(parsed.single, isA<OpenSSHEd25519KeyPair>());
    final line = PhoneSshKeyStore.formatPublicKey(key);
    expect(line, startsWith('ssh-ed25519 '));
    final parts = line.split(' ');
    expect(parts, hasLength(3));
    expect(base64Decode(parts[1]), parsed.single.toPublicKey().encode());
  });
}
