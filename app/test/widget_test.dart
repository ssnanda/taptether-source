import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  testWidgets('My Devices is the default dashboard; pairing is optional',
      (tester) async {
    await tester.pumpWidget(const TapTetherApp());
    await tester.pumpAndSettle();
    expect(find.text('My Devices'), findsOneWidget);
    expect(find.text('Pair with a computer agent'), findsNothing);
    await tester.tap(find.text('Pair computer').first);
    await tester.pump();
    expect(find.text('Pair with a computer agent'), findsOneWidget);
  });

  testWidgets('Drawer contains navigation and grouped setup actions',
      (tester) async {
    await tester.pumpWidget(const TapTetherApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation'));
    await tester.pumpAndSettle();
    expect(find.text('SSH Keys'), findsOneWidget);
    expect(find.text('Security & Appearance'), findsOneWidget);
    expect(find.text('Add & Discover'), findsOneWidget);
    await tester.tap(find.text('Add & Discover'));
    await tester.pumpAndSettle();
    expect(find.text('Discover computers'), findsOneWidget);
    expect(find.text('Install Agent'), findsOneWidget);
    expect(find.text('Install Ubuntu agent'), findsNothing);
  });

  testWidgets('Light appearance is used by default',
      (tester) async {
    await tester.pumpWidget(const TapTetherApp());
    await tester.pumpAndSettle();
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.themeMode, ThemeMode.light);
  });
}
