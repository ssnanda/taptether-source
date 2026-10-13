import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/ubuntu_install_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  testWidgets('IP field exposes a dot and blocks malformed addresses',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: UbuntuInstallScreen(
      initialHost: '192.168.68.',
      onInstalled: (_) async => true,
    )));
    await tester.pumpAndSettle();

    final ipField = tester.widget<TextField>(
        find.byType(TextField).first);
    expect(ipField.keyboardType, TextInputType.url);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);

    await tester.enterText(
        find.byType(TextFormField).first, '192.168.68.999');
    await tester.pump();
    expect(find.textContaining('Enter four dot-separated numbers'),
        findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);

    await tester.enterText(
        find.byType(TextFormField).first, '192.168.68.81');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });

  testWidgets('installer has no fingerprint input and validates before SSH',
      (tester) async {
    var paired = false;
    await tester.pumpWidget(MaterialApp(home: UbuntuInstallScreen(
      initialHost: '192.168.68.87',
      onInstalled: (_) async {
        paired = true;
        return true;
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('Verified SSH host SHA256 fingerprint'), findsNothing);
    expect(find.text('Ubuntu IP address'), findsOneWidget);
    await tester.ensureVisible(find.text('Install & pair'));
    await tester.tap(find.text('Install & pair'));
    await tester.pump();
    expect(find.text('Enter a valid Ubuntu username.'), findsOneWidget);
    expect(paired, isFalse);
  });
}
