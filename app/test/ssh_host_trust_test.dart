import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/ssh_host_trust.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  const original = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const replaced = 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

  test('first authenticated connection is pinned across store instances',
      () async {
    final first = SshHostTrustStore();
    expect(await first.trustedFingerprint('192.168.68.87'), isNull);
    await first.rememberAuthenticated('192.168.68.87', original);
    expect(await SshHostTrustStore().trustedFingerprint('192.168.68.87'),
        original);
    await first.rememberAuthenticated('192.168.68.87', original);
  });

  test('pinning is per-host and a changed identity is never overwritten',
      () async {
    final store = SshHostTrustStore();
    await store.rememberAuthenticated('192.168.68.87', original);
    expect(await store.trustedFingerprint('192.168.68.88'), isNull);
    await expectLater(
      store.rememberAuthenticated('192.168.68.87', replaced),
      throwsA(isA<StateError>()),
    );
    expect(await store.trustedFingerprint('192.168.68.87'), original);
  });

  test('malformed fingerprints are rejected before storage', () async {
    final store = SshHostTrustStore();
    await expectLater(store.rememberAuthenticated('192.168.68.87', 'junk'),
        throwsFormatException);
    expect(await store.trustedFingerprint('192.168.68.87'), isNull);
  });
}
