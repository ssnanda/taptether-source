import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/xbox_manual_targets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('Remote Features confirmation persists by Xbox address', () async {
    final setup = XboxRemoteSetupStore();
    expect(await setup.confirmed('192.168.68.82'), false);
    await setup.setConfirmed('192.168.68.82', true);
    expect(await XboxRemoteSetupStore().confirmed('192.168.68.82'), true);
    expect(await setup.confirmed('192.168.68.84'), false);
    await setup.setConfirmed('192.168.68.82', false);
    expect(await setup.confirmed('192.168.68.82'), false);
  });

  test('Remote Features confirmation rejects public addresses', () async {
    final setup = XboxRemoteSetupStore();
    await expectLater(setup.setConfirmed('8.8.8.8', true),
        throwsFormatException);
    expect(await setup.confirmed('8.8.8.8'), false);
  });
}
