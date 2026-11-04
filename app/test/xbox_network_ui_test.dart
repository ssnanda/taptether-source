import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/xbox_remote_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('Xbox IP is first, with separate manual entire-network scan',
      (tester) async {
    final targets = <String?>[];
    await tester.pumpWidget(MaterialApp(home: XboxRemoteScreen(
      initialHost: '192.168.68.84',
      discovery: ({String? targetIp}) async {
        targets.add(targetIp);
        return [];
      },
    )));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Xbox IP address'), findsOneWidget);
    expect(find.text('Connect Xbox'), findsOneWidget);
    expect(find.text('Save Xbox to Devices'), findsOneWidget);
    expect(find.text('Check Xbox IP'), findsOneWidget);
    expect(find.text('Find Xbox across this Wi-Fi'), findsOneWidget);
    expect(find.text('Check Xbox IP').evaluate().first.renderObject,
        isNotNull);
    expect(find.text('Open Xbox Remote Play'), findsOneWidget);
    expect(find.text('Deep network diagnostics (slower)'), findsOneWidget);
    expect(find.textContaining('Remote Features can already be enabled'),
        findsOneWidget);
    expect(find.textContaining('General → Network settings'),
        findsOneWidget);
    await tester.tap(find.text('Check Xbox IP'));
    await tester.pumpAndSettle();
    expect(targets, ['192.168.68.84']);
  });

  testWidgets('Connect launches actual Microsoft session without UDP scan',
      (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(home: XboxRemoteScreen(
      initialHost: '192.168.68.82',
      connect: () async {
        opened++;
        return true;
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect Xbox'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.textContaining('Microsoft Remote Play opened'), findsOneWidget);
  });

  testWidgets('Save Xbox IP works without an Xbox discovery response',
      (tester) async {
    var saved = 0;
    await tester.pumpWidget(MaterialApp(home: XboxRemoteScreen(
      initialHost: '192.168.68.82',
      onSaved: () async { saved++; },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save Xbox to Devices'));
    await tester.pumpAndSettle();
    expect(find.text('Save Xbox address'), findsOneWidget);
    expect(find.textContaining('not been authenticated'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    await tester.pumpAndSettle();
    expect(saved, 1);
    expect(find.textContaining('saved in Devices as an unverified address'),
        findsOneWidget);
  });
}
