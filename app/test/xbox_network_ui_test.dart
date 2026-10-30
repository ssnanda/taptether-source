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
    expect(find.text('Check Xbox IP'), findsOneWidget);
    expect(find.text('Scan entire local network'), findsOneWidget);
    expect(find.text('Check Xbox IP').evaluate().first.renderObject,
        isNotNull);
    await tester.tap(find.text('Check Xbox IP'));
    await tester.pumpAndSettle();
    expect(targets, ['192.168.68.84']);
  });
}
