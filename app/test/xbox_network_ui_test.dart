import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/xbox_remote_screen.dart';
import 'package:taptether/xbox_manual_targets.dart';
import 'package:taptether/xbox_smartglass.dart';

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
    expect(find.widgetWithText(TextField, 'Xbox IP'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.textContaining('Remote Features'), findsNothing);
    expect(find.text('Deep scan'), findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey('xbox-scan'))).dx,
        lessThan(tester.getTopLeft(
          find.byKey(const ValueKey('xbox-connect'))).dx));
    expect(tester.getTopLeft(find.byKey(
        const ValueKey('xbox-connect'))).dx,
        lessThan(tester.getTopLeft(
          find.byKey(const ValueKey('xbox-save-manual'))).dx));
    await tester.tap(find.byKey(const ValueKey('xbox-diagnostics-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Check IP'), findsOneWidget);
    expect(find.text('Deep scan'), findsOneWidget);
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
    await tester.tap(find.byKey(const ValueKey('xbox-connect')));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.text('Opened'), findsOneWidget);
    final saved = await XboxManualTargetStore().read();
    expect(saved, hasLength(1));
    expect(saved.single.host, '192.168.68.82');
    expect(await XboxConsoleStore().lastTargetIp(), '192.168.68.82');
  });

  testWidgets('Scan checks the typed Xbox IP directly instead of sweeping Wi-Fi',
      (tester) async {
    final targets = <String?>[];
    await tester.pumpWidget(MaterialApp(home: XboxRemoteScreen(
      initialHost: '192.168.68.85',
      discovery: ({String? targetIp}) async {
        targets.add(targetIp);
        return [];
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('xbox-scan')));
    await tester.pumpAndSettle();
    expect(targets, ['192.168.68.85']);
    expect(find.textContaining('No compatible Xbox LAN reply from '
        '192.168.68.85'), findsOneWidget);
  });

  testWidgets('Save Xbox IP works without an Xbox discovery response',
      (tester) async {
    var saved = 0;
    await tester.pumpWidget(MaterialApp(home: XboxRemoteScreen(
      initialHost: '192.168.68.82',
      onSaved: () async { saved++; },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('xbox-save-manual')));
    await tester.pumpAndSettle();
    expect(find.text('Save Xbox'), findsOneWidget);
    expect(find.textContaining('not been authenticated'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    await tester.pumpAndSettle();
    expect(saved, 1);
    expect(find.text('Saved'), findsOneWidget);
  });
}
