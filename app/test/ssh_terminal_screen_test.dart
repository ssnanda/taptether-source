import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/ssh_terminal_screen.dart';

void main() {
  test('SSH sends multiline scripts in one payload, preserving blank lines', () {
    expect(prepareSshTerminalInput('pwd\nwhoami'), 'pwd\rwhoami\r');
    expect(prepareSshTerminalInput('pwd\r\n\r\nwhoami\r\n'),
        'pwd\r\rwhoami\r');
    expect(prepareSshTerminalInput('pwd\rwhoami'), 'pwd\rwhoami\r');
    expect(prepareSshTerminalInput('whoami'), 'whoami\r');
    expect(prepareSshTerminalInput(''), '');
    expect(prepareSshTerminalInput('echo one\n\necho two\n'),
        'echo one\r\recho two\r');
    expect(prepareSshTerminalInput("printf '[Service]\\nEnabled=yes\\n'\n"
        'systemctl daemon-reload'),
        "printf '[Service]\\nEnabled=yes\\n'\rsystemctl daemon-reload\r");
  });

  test('SSH script detection and multiline input preserve literal line breaks',
      () {
    expect(isSshScriptInput('pwd'), isFalse);
    expect(isSshScriptInput('pwd\nwhoami'), isTrue);
    expect(isSshScriptInput('echo one\r\necho two'), isTrue);
    expect(prepareSshScriptInput('pwd\nwhoami'),
        'pwd\nwhoami\n');
    expect(prepareSshScriptInput('echo one\r\n\r\necho two\r\n'),
        'echo one\n\necho two\n');
    expect(prepareSshScriptInput('echo one\recho two'),
        'echo one\necho two\n');
    expect(prepareSshScriptInput(''), isEmpty);
    expect(prepareSshScriptInput('   \n  '), isEmpty);
    const heredoc = 'cat > /tmp/example <<EOF\nline one\n\n'
        'line three\nEOF\nprintf "done\\n"';
    expect(prepareSshScriptInput(heredoc),
        '$heredoc\n');
  });

  test('SSH output separates CR-only lines and split CRLF correctly', () {
    final f = SshTerminalOutputFormatter();
    expect(f.format('root@host:# pwd\r'), 'root@host:# pwd\n');
    expect(f.format('\n/home/user\rnext\r\n'), '/home/user\nnext\n');
    expect(f.format('a\nb\r'), 'a\nb\n');
    expect(f.format('\nc'), 'c');
    f.reset();
    expect(f.format('fresh\r\n'), 'fresh\n');
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('SSH Terminal provides LAN, credentials and command workflow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: SshTerminalScreen()));
    await tester.pumpAndSettle();

    expect(find.text('SSH'), findsOneWidget);
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
