import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/app_security.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('PIN configuration persists and refuses incorrect PINs', () async {
    final security = AppSecurity.instance;
    await security.load();
    expect(security.enabled, isFalse);
    expect(security.unlocked, isTrue);

    expect(AppSecurity.isValidPin('123456'), isTrue);
    expect(AppSecurity.isValidPin('1234'), isFalse);
    expect(AppSecurity.isValidPin('12345a'), isFalse);

    await security.setPin('427915');
    expect(security.enabled, isTrue);
    expect(await security.verifyPin('000000'), isFalse);
    expect(await security.verifyPin('427915'), isTrue);
    await security.load();
    expect(security.unlocked, isFalse);
    expect(await security.verifyPin('427915'), isTrue);
  });

  test('background lock timeouts are validated and persisted', () async {
    final security = AppSecurity.instance;
    await security.load();
    await security.setPin('562814');
    await security.setDelay(60);
    await security.load();
    expect(security.delaySeconds, 60);
    security.unlock();
    expect(security.unlocked, isTrue);
    security.lock();
    expect(security.unlocked, isFalse);
    await expectLater(security.setDelay(999),
        throwsA(isA<FormatException>()));
  });
}
