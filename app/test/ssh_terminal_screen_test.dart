import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/ssh_terminal_screen.dart';

void main() {
  test('SSH terminal preserves pasted commands and normalizes line endings', () {
    expect(prepareSshTerminalInput('pwd\nwhoami'), 'pwd\nwhoami\n');
    expect(prepareSshTerminalInput('pwd\r\nwhoami\r\n'), 'pwd\nwhoami\n');
    expect(prepareSshTerminalInput('pwd\rwhoami'), 'pwd\nwhoami\n');
    expect(prepareSshTerminalInput('whoami'), 'whoami\n');
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('SSH Terminal provides LAN, credentials and command workflow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: SshTerminalScreen()));
    await tester.pumpAndSettle();

    expect(find.text('SSH Terminal'), findsOneWidget);
    expect(find.byKey(const ValueKey('ssh-host')), findsOneWidget);
    expect(find.byKey(const ValueKey('ssh-port')), findsOneWidget);
    expect(find.byKey(const ValueKey('ssh-username')), findsOneWidget);
    expect(find.byKey(const ValueKey('ssh-login-method')), findsOneWidget);
    // With no saved phone key, password mode is the usable default.
    expect(find.byKey(const ValueKey('ssh-password')), findsOneWidget);
    await tester.tap(find.text('Phone key'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No phone SSH key'), findsOneWidget);
    await tester.tap(find.text('Password'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ssh-password')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ssh-connect')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a private LAN IP'), findsOneWidget);
  });

  testWidgets('SSH does not connect to a public address',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: SshTerminalScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Password'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ssh-host')), '8.8.8.8');
    await tester.enterText(find.byKey(const ValueKey('ssh-username')), 'user');
    await tester.enterText(find.byKey(const ValueKey('ssh-password')), 'secret');
    await tester.tap(find.byKey(const ValueKey('ssh-connect')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a private LAN IP'), findsOneWidget);
    expect(find.byKey(const ValueKey('ssh-command')), findsNothing);
  });
}
