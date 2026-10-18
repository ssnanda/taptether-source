import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/app_security.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    final pending = Completer<bool>();
    await tester.pumpWidget(MaterialApp(
      home: AppLockGate(
        biometricVerifierForTesting: (reason) {
          requests++;
          expect(reason, 'Unlock TapTether');
          return pending.future;
        },
        child: const Scaffold(body: Text('Saved devices are private')),
      ),
    ));
    await tester.pump();
    expect(requests, 1);
    expect(find.text('Saved devices are private'), findsNothing);
    expect(find.text('Six-digit app PIN'), findsNothing);
    await tester.pump();
    expect(requests, 1); // rebuild cannot re-prompt
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Saved devices are private'), findsOneWidget);
    expect(AppSecurity.instance.unlocked, isTrue);
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
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('Six-digit app PIN'), findsOneWidget);
    expect(find.text('Unlock with PIN'), findsOneWidget);
    expect(find.text('Devices dashboard'), findsNothing);
    await tester.pump();
    await tester.pump();
    expect(requests, 1);
    await tester.enterText(find.byType(TextField), '427915');
    await tester.tap(find.text('Unlock with PIN'));
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('Unlocked remote'), findsOneWidget);
    AppSecurity.instance.lock();
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('Unlocked remote'), findsOneWidget);
  });
}
