import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/app_security.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Bound frame pumping: animated PIN focus/cursors should never make a
  // security regression test wait indefinitely for a globally settled tree.
  Future<void> pumpLockFrames(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> configureBiometricLock() async {
    // A non-secret PBKDF2-HMAC-SHA256 test vector for PIN 427915 with salt
    // 00..0f, 180000 iterations. Avoid recomputing the deliberately costly
    // KDF during each widget test; verifyPin still checks it normally.
    // Emulates an existing enrolled PIN + Face ID configuration.
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'taptether.lock.enabled.v1': 'true',
      'taptether.lock.bio.v1': 'true',
      'taptether.lock.salt.v1': 'AAECAwQFBgcICQoLDA0ODw==',
      'taptether.lock.hash.v1': 'BRiwTQZU4RM38V3CaCRoQJuE3jiZuggsuWiueR0jyXs=',
    });
    final security = AppSecurity.instance;
    await security.load();
    expect(security.enabled, isTrue);
    expect(security.biometricEnabled, isTrue);
    expect(security.unlocked, isFalse);
  }

  testWidgets('automatically requests Face ID, unlocks without tapping',
      (tester) async {
    await configureBiometricLock();
    var requests = 0;
    await tester.pumpWidget(MaterialApp(
      home: AppLockGate(
        biometricVerifierForTesting: (reason) async {
          requests++;
          expect(reason, 'Unlock TapTether');
          return true;
        },
        child: const Scaffold(body: Text('Saved devices are private')),
      ),
    ));
    await pumpLockFrames(tester);
    expect(requests, 1);
    expect(find.text('Saved devices are private'), findsOneWidget);
    expect(AppSecurity.instance.unlocked, isTrue);
    await tester.pump();
    expect(requests, 1); // rebuild cannot re-prompt
  });

  testWidgets('canceled Face ID falls back to PIN once, without a prompt loop',
      (tester) async {
    await configureBiometricLock();
    var requests = 0;
    await tester.pumpWidget(MaterialApp(
      home: AppLockGate(
        biometricVerifierForTesting: (_) async {
          requests++;
          return false;
        },
        child: const Scaffold(body: Text('Devices dashboard')),
      ),
    ));
    await pumpLockFrames(tester);
    expect(requests, 1);
    expect(find.text('Six-digit app PIN'), findsOneWidget);
    expect(find.text('Unlock with PIN'), findsOneWidget);
    expect(find.text('Devices dashboard'), findsNothing);
    await tester.pump();
    await tester.pump();
    expect(requests, 1);
    await tester.enterText(find.byType(TextField), '427915');
    await tester.tap(find.text('Unlock with PIN'));
    await pumpLockFrames(tester);
    expect(find.text('Devices dashboard'), findsOneWidget);
    expect(AppSecurity.instance.unlocked, isTrue);
  });

  testWidgets('relocking schedules one new biometric request',
      (tester) async {
    await configureBiometricLock();
    var requests = 0;
    await tester.pumpWidget(MaterialApp(
      home: AppLockGate(
        biometricVerifierForTesting: (_) async {
          requests++;
          return true;
        },
        child: const Scaffold(body: Text('Unlocked remote')),
      ),
    ));
    await pumpLockFrames(tester);
    expect(requests, 1);
    expect(find.text('Unlocked remote'), findsOneWidget);
    AppSecurity.instance.lock();
    await pumpLockFrames(tester);
    expect(requests, 2);
    expect(find.text('Unlocked remote'), findsOneWidget);
  });
}
