import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/device_backup_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'taptether.backup.saved-password.v1';
  const unprotected = 'taptether.backup.unprotected.v1';
  const savedPassword = 'previous-strong-backup-password';

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  testWidgets('first backup password is set on the backup screen, once',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DeviceBackupScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Encrypt device backup'), findsNothing);
    expect(find.byKey(const ValueKey('backup-password-input')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('backup-password-confirm')),
        findsOneWidget);
    expect(find.text('Encrypt backups (optional)'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('backup-password-input')),
        'a-secure-password-for-all-backups');
    await tester.enterText(
        find.byKey(const ValueKey('backup-password-confirm')),
        'a-secure-password-for-all-backups');
    await tester.ensureVisible(
        find.byKey(const ValueKey('save-backup-password')));
    await tester.tap(find.byKey(const ValueKey('save-backup-password')));
    await tester.pumpAndSettle();

    expect(find.text('Password saved securely'), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-password-input')), findsNothing);
    expect(await const FlutterSecureStorage().read(key: key),
        'a-secure-password-for-all-backups');
    expect(await const FlutterSecureStorage().read(key: unprotected), isNull);
  });

  testWidgets('saved password is reused, with optional inline change',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      key: savedPassword,
    });
    await tester.pumpWidget(const MaterialApp(home: DeviceBackupScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Password saved securely'), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-password-input')), findsNothing);
    expect(find.text('Encrypt device backup'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('change-backup-password')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('backup-password-input')), findsOneWidget);
    expect(await const FlutterSecureStorage().read(key: key), savedPassword);
  });

  testWidgets('turning off encryption is a deliberate, confirmed choice',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({key: savedPassword});
    await tester.pumpWidget(const MaterialApp(home: DeviceBackupScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(
        const ValueKey('backup-password-protection')));
    // The busy indicator remains animated while the consent dialog is open.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Disable password protection?'), findsOneWidget);
    expect(find.textContaining('NOT encrypted'), findsOneWidget);
    await tester.tap(find.text('Use without encryption'));
    await tester.pumpAndSettle();

    expect(find.text('Unencrypted backups expose saved device credentials'),
        findsOneWidget);
    expect(await const FlutterSecureStorage().read(key: unprotected), 'true');
    // Old encrypted backup passwords remain available for restoring them.
    expect(await const FlutterSecureStorage().read(key: key), savedPassword);
  });

  testWidgets('invalid inline password shows error, never a setup dialog',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DeviceBackupScreen()));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('backup-password-input')), 'short');
    await tester.enterText(
        find.byKey(const ValueKey('backup-password-confirm')), 'short');
    await tester.ensureVisible(
        find.byKey(const ValueKey('save-backup-password')));
    await tester.tap(find.byKey(const ValueKey('save-backup-password')));
    await tester.pumpAndSettle();
    expect(find.textContaining('at least 12 characters'), findsWidgets);
    expect(find.text('Encrypt device backup'), findsNothing);
    expect(await const FlutterSecureStorage().read(key: key), isNull);
  });
}
