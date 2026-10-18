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
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    final security = AppSecurity.instance;
    await security.load();
    await security.setPin('427915');
    // Emulate a previously enrolled/confirmed Face ID setting. Production
    // setBiometrics requires actual OS enrollment and verification.
    await const FlutterSecureStorage().write(
      key: 'taptether.lock.bio.v1', value: 'true');
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
