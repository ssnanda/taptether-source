import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/xbox_manual_targets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('manual Xbox IP can be saved and recovered without a certificate',
      () async {
    final store = XboxManualTargetStore();
    await store.save(const XboxManualTarget(
        host: '192.168.68.82', name: 'Family Xbox', location: 'Home'));
    final saved = await XboxManualTargetStore().read();
    expect(saved, hasLength(1));
    expect(saved.first.host, '192.168.68.82');
    expect(saved.first.name, 'Family Xbox');
    expect(saved.first.location, 'Home');
    expect(saved.first.toJson().containsKey('certificateSha256'), false);
    expect(saved.first.toJson().containsKey('accessToken'), false);
  });

  test('manual targets can be renamed, deduplicated, and forgotten', () async {
    final store = XboxManualTargetStore();
    await store.save(const XboxManualTarget(
        host: '192.168.68.82', name: 'Xbox'));
    await store.save(const XboxManualTarget(
        host: '192.168.68.82', name: 'Living Room Xbox'));
    expect(await store.read(), hasLength(1));
    expect((await store.read()).single.name, 'Living Room Xbox');
    await store.remove('192.168.68.82');
    expect(await store.read(), isEmpty);
  });

  test('manual IP storage rejects public IPs and invalid labels', () async {
    final store = XboxManualTargetStore();
    await expectLater(store.save(const XboxManualTarget(
        host: '8.8.8.8', name: 'Not Xbox')), throwsFormatException);
    await expectLater(store.save(const XboxManualTarget(
        host: '192.168.68.82', name: '  ')), throwsFormatException);
    expect(await store.read(), isEmpty);
  });

  test('malformed saved targets do not crash dashboard loading', () async {
    final storage = FlutterSecureStorage();
    await storage.write(key: XboxManualTargetStore.key, value: '{bad');
    expect(await XboxManualTargetStore().read(), isEmpty);
    await storage.write(key: XboxManualTargetStore.key,
        value: '[{"host":"8.8.8.8","name":"Public IP"},'
            '{"host":"192.168.68.82","name":"Xbox"},'
            '{"host":"192.168.68.82","name":"Duplicate"}]');
    expect((await XboxManualTargetStore().read()).length, 1);
  });
}
