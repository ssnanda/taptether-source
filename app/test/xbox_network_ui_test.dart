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
    expect(find.text('3 · Connect & test controller'), findsOneWidget);
    expect(find.byKey(const ValueKey('xbox-remote-features')), findsOneWidget);
    expect(find.text('Save Xbox to Devices'), findsOneWidget);
    expect(find.text('Check IP'), findsOneWidget);
    expect(find.text('Scan Wi-Fi'), findsOneWidget);
    expect(find.text('Check IP').evaluate().first.renderObject,
        isNotNull);
    expect(find.text('Deep network diagnostics (slower)'), findsOneWidget);
    await tester.tap(find.text('Check IP'));
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
    await tester.ensureVisible(find.byKey(
        const ValueKey('xbox-remote-features')));
    await tester.tap(find.byKey(const ValueKey('xbox-remote-features')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('xbox-connect')));
    await tester.tap(find.byKey(const ValueKey('xbox-connect')));
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
    await tester.ensureVisible(find.text('Save Xbox to Devices'));
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
