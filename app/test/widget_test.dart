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
    expect(find.text('Join Wi-Fi to control your devices.'), findsOneWidget);
    expect(find.text('Manage saved devices'), findsOneWidget);
    expect(find.text('SSH keys'), findsOneWidget);
    expect(find.text('Settings & backups'), findsOneWidget);
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
    expect(find.text('About'), findsOneWidget);
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
