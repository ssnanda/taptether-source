import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  testWidgets('without Wi-Fi the dashboard has no LAN controls',
      (tester) async {
    await tester.pumpWidget(const TapTetherApp());
    await tester.pumpAndSettle();
    // The platform Wi-Fi check may still be pending in a widget test.
    // Neither the checking state nor confirmed offline mode may offer
    // LAN-only actions or report fake connectivity.
    final joined = find.text('Join Wi-Fi to control your devices.');
    final checking = find.text('Checking Wi-Fi…');
    expect(joined.evaluate().isNotEmpty || checking.evaluate().isNotEmpty,
        isTrue);
    if (joined.evaluate().isNotEmpty) {
      expect(find.text('Manage saved devices'), findsOneWidget);
      expect(find.text('SSH keys'), findsOneWidget);
      expect(find.text('Settings & backups'), findsOneWidget);
    }
    expect(find.text('Pair with a computer agent'), findsNothing);
    expect(find.text('Scan IPs'), findsNothing);
    expect(find.text('Not connected'), findsNothing);
  });

  testWidgets('offline drawer keeps settings but hides LAN features',
      (tester) async {
    await tester.pumpWidget(const TapTetherApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation'));
    await tester.pumpAndSettle();
    expect(find.text('My Devices'), findsOneWidget);
    expect(find.text('SSH Keys'), findsOneWidget);
    expect(find.text('Security & Appearance'), findsOneWidget);
    expect(find.text('About TapTether'), findsOneWidget);
    expect(find.text('Download agents'), findsOneWidget);
    expect(find.text('TV Remotes'), findsNothing);
    expect(find.text('Add & Discover'), findsNothing);
    expect(find.text('Discover computers'), findsNothing);
    expect(find.text('Install Agent'), findsNothing);
  });

  testWidgets('Light appearance is used by default', (tester) async {
    await tester.pumpWidget(const TapTetherApp());
    await tester.pumpAndSettle();
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.themeMode, ThemeMode.light);
  });
}
