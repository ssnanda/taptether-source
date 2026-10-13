import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/ubuntu_install_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

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
