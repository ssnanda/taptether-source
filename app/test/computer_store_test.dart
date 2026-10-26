import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/computer_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const phoneEnrollmentId = '0123456789abcdef0123456789abcdef';
  const ubuntuPin =
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const macPin =
      'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
      'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

  SavedComputer computer({
    required String id,
    required String name,
    required String host,
    required String pin,
    required String platform,
    String deviceId = phoneEnrollmentId,
  }) =>
      SavedComputer(
        id: id,
        name: name,
        host: host,
        token: '',
        fingerprint: pin,
        deviceId: deviceId,
        platform: platform,
      );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('pairing the same phone to Mac and Ubuntu keeps both computers',
      () async {
    final store = ComputerStore();
    final ubuntu = computer(
      id: 'ubuntu-record',
      name: 'iMac.Ubuntu',
      host: '192.168.68.90',
      pin: ubuntuPin,
      platform: 'linux',
    );
    final mac = computer(
      id: 'mac-record',
      name: 'MacBook Pro',
      host: '192.168.68.81',
      pin: macPin,
      platform: 'darwin',
    );
    expect((await store.upsert(ubuntu)).length, 1);
    expect((await store.upsert(mac)).length, 2);
    final saved = await ComputerStore().read();
    expect(saved.map((d) => d.name), containsAll(['iMac.Ubuntu', 'MacBook Pro']));
    expect(saved.map((d) => d.platform), containsAll(['linux', 'darwin']));
    expect(saved.every((d) => d.deviceId == phoneEnrollmentId), isTrue);
  });

  test('reconnecting Mac changes only Mac entry, never deletes Ubuntu',
      () async {
    final store = ComputerStore();
    final ubuntu = computer(
      id: 'ubuntu-record', name: 'Ubuntu',
      host: '192.168.68.90', pin: ubuntuPin, platform: 'linux');
    final mac = computer(
      id: 'mac-record', name: 'Mac',
      host: '192.168.68.81', pin: macPin, platform: 'darwin');
    await store.upsert(ubuntu);
    await store.upsert(mac);
    final renamed = computer(
      id: 'mac-record', name: 'Office Mac',
      host: '192.168.68.99', pin: macPin, platform: 'darwin');
    final entries = await store.upsert(renamed);
    expect(entries, hasLength(2));
    expect(entries.first.name, 'Office Mac');
    expect(entries.first.host, '192.168.68.99');
    expect(entries.last.name, 'Ubuntu');
    expect((await store.read()), hasLength(2));
  });

  test('reused IP does not merge machines with different TLS certificates',
      () async {
    final store = ComputerStore();
    await store.upsert(computer(
      id: 'ubuntu', name: 'Ubuntu',
      host: '192.168.68.90', pin: ubuntuPin, platform: 'linux'));
    final saved = await store.upsert(computer(
      id: 'mac', name: 'Mac',
      host: '192.168.68.90', pin: macPin, platform: 'darwin'));
    expect(saved, hasLength(2));
  });

  test('re-pairing same verified certificate replaces old record', () async {
    final store = ComputerStore();
    await store.upsert(computer(
      id: 'old-record', name: 'Ubuntu',
      host: '192.168.68.90', pin: ubuntuPin, platform: 'linux'));
    final saved = await store.upsert(computer(
      id: 'new-record', name: 'Ubuntu renamed',
      host: '192.168.68.91', pin: ubuntuPin, platform: 'linux'));
    expect(saved, hasLength(1));
    expect(saved.single.name, 'Ubuntu renamed');
  });

  test('read of existing multi-computer storage retains shared phone ID',
      () async {
    final store = ComputerStore();
    await store.upsert(computer(
      id: 'mac', name: 'Mac',
      host: '192.168.68.81', pin: macPin, platform: 'darwin'));
    await store.upsert(computer(
      id: 'ubuntu', name: 'Ubuntu',
      host: '192.168.68.90', pin: ubuntuPin, platform: 'linux'));
    final newStore = ComputerStore();
    expect((await newStore.read()).map((d) => d.id),
        containsAll(['mac', 'ubuntu']));
  });
}
