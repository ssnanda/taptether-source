import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/phone_ssh_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('multiple named Ed25519 identities, rename, selection and delete', () async {
    final store = PhoneSshKeyStore();
    final first = await store.generateNamed('Personal Ubuntu');
    final second = await store.generateNamed('Lab Mac');
    final names = await store.listKeys();
    expect(names.length, 2);
    expect(names.map((key) => key.id).toSet().length, 2);
    expect(first.publicKey, startsWith('ssh-ed25519 '));
    expect(second.publicKey, startsWith('ssh-ed25519 '));
    expect(first.publicKey, isNot(second.publicKey));
    expect(await store.selectedId(), first.id);
    await store.selectKey(second.id);
    expect(await store.selectedId(), second.id);
    final original = await store.publicKeyLine(id: second.id);
    await store.renameKey(second.id, 'Renamed macOS host');
    final renamed = await store.listKeys();
    expect(renamed.last.name, 'Renamed macOS host');
    expect(await store.publicKeyLine(id: second.id), original);
    expect(await store.authenticationIdentities(id: second.id), hasLength(1));
    await store.deleteKey(second.id);
    expect(await store.selectedId(), first.id);
    expect((await store.listKeys()).map((key) => key.id), isNot(contains(second.id)));
  });

  test('import never overwrites an existing private key', () async {
    final store = PhoneSshKeyStore();
    final first = await store.generateNamed('Original');
    final pem = (await store.load(id: first.id))!.toPem();
    await expectLater(
      store.importNamed('Duplicate', pem),
      throwsA(isA<StateError>()),
    );
    expect((await store.listKeys()).length, 1);
  });

  test('legacy key is migrated without changing its SSH public key', () async {
    final source = PhoneSshKeyStore();
    final old = await source.generateNamed('Original');
    final pem = await source.exportPrivatePem(old.id);
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'taptether.ssh.ed25519.private.v1': pem,
    });
    final upgraded = PhoneSshKeyStore();
    final migrated = await upgraded.listKeys();
    expect(migrated, hasLength(1));
    expect(migrated.single.publicKey, old.publicKey);
    expect(await upgraded.selectedId(), migrated.single.id);
    expect((await upgraded.listKeys()).length, 1);
  });

  test('empty key names are rejected without changing stored identities', () async {
    final store = PhoneSshKeyStore();
    await expectLater(store.generateNamed('  '),
      throwsA(isA<FormatException>()));
    expect(await store.listKeys(), isEmpty);
  });
}
