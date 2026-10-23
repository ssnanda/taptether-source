import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_webos_client.dart';
import 'package:taptether/lg_webos_screen.dart';
import 'package:taptether/samsung_tv_client.dart';
import 'package:taptether/samsung_tv_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LG detail shows ONLY tapped TV; Wake uses that exact host',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      LgTvStore.key: jsonEncode([
        const LgTvDevice(host: '192.168.68.41', name: 'Family Room TV',
          clientKey: 'paired-one', macAddress: '00:11:22:33:44:11').toJson(),
        const LgTvDevice(host: '192.168.68.42', name: 'DadaDadi TV',
          clientKey: 'paired-two', macAddress: '00:11:22:33:44:22').toJson(),
      ]),
    });
    final woken = <String>[];
    await tester.pumpWidget(MaterialApp(home: LgWebOsScreen(
      initialHost: '192.168.68.42',
      autoReconnect: false,
      wakeDevice: (tv) async => woken.add(tv.host),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lg-selected-tv-card')),
        findsOneWidget);
    expect(find.text('Family Room TV'), findsNothing);
    expect(find.text('Turn on DadaDadi TV'), findsOneWidget);
    expect(find.byTooltip('Discover LG TVs'), findsNothing);
    expect(find.text('Discover LG TVs'), findsNothing);
    expect(find.byKey(const ValueKey('lg-power-toggle')), findsNothing);

    await tester.tap(find.byKey(
      const ValueKey('lg-power-selected-tv')));
    await tester.pump();
    expect(woken, ['192.168.68.42']);
    expect(find.textContaining('Power-on signal sent'), findsOneWidget);
  });

  testWidgets('LG Power On without MAC guides setup and saves reviewed hint',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      LgTvStore.key: jsonEncode([
        const LgTvDevice(
          host: '192.168.68.89', name: 'DadaDadi TV',
          clientKey: 'paired', tlsPin: 'certificate-pin',
        ).toJson(),
      ]),
    });
    var hintsRequested = 0;
    await tester.pumpWidget(MaterialApp(home: LgWebOsScreen(
      initialHost: '192.168.68.89',
      autoReconnect: false,
      lookupMacHint: (host) async {
        hintsRequested++;
        expect(host, '192.168.68.89');
        return 'aa-bb-cc-dd-ee-ff';
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('Set up Power On for DadaDadi TV'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lg-power-selected-tv')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lg-mac-setup-field')), findsOneWidget);
    expect(find.text('Turn on DadaDadi TV'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('lg-find-mac-hint')));
    await tester.pumpAndSettle();
    expect(hintsRequested, 1);
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('lg-mac-setup-field')));
    expect(field.controller!.text, 'AA:BB:CC:DD:EE:FF');
    expect(find.textContaining('Verify it belongs to this TV'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lg-save-mac')));
    await tester.pumpAndSettle();
    expect(find.text('Turn on DadaDadi TV'), findsOneWidget);
    final stored = await LgTvStore().read();
    expect(stored.single.macAddress, 'AA:BB:CC:DD:EE:FF');
    expect(stored.single.clientKey, 'paired');
    expect(stored.single.tlsPin, 'certificate-pin');
  });

  testWidgets('LG missing MAC setup cancellation never changes saved pairing',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      LgTvStore.key: jsonEncode([
        const LgTvDevice(host: '192.168.68.89',
          name: 'DadaDadi TV', clientKey: 'saved-pairing').toJson(),
      ]),
    });
    await tester.pumpWidget(const MaterialApp(home: LgWebOsScreen(
      initialHost: '192.168.68.89', autoReconnect: false,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lg-power-selected-tv')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Set up Power On for DadaDadi TV'), findsOneWidget);
    final stored = await LgTvStore().read();
    expect(stored.single.macAddress, isEmpty);
    expect(stored.single.clientKey, 'saved-pairing');
  });

  testWidgets('LG detail refuses to fall back when selected saved TV is gone',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      LgTvStore.key: jsonEncode([
        const LgTvDevice(host: '192.168.68.41',
          name: 'Family Room TV', clientKey: 'paired').toJson(),
      ]),
    });
    await tester.pumpWidget(const MaterialApp(home: LgWebOsScreen(
      initialHost: '192.168.68.42', autoReconnect: false,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Family Room TV'), findsNothing);
    expect(find.byKey(const ValueKey('lg-power-selected-tv')),
        findsNothing);
    expect(find.text('Selected TV unavailable'), findsOneWidget);
  });

  testWidgets('Samsung detail shows ONLY tapped TV; Wake uses that exact host',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      SamsungTvStore.key: jsonEncode([
        const SamsungTvDevice(host: '192.168.68.51',
          name: 'Kitchen Samsung', token: 'token-one',
          macAddress: '00:11:22:33:44:51').toJson(),
        const SamsungTvDevice(host: '192.168.68.52',
          name: 'Office Samsung', token: 'token-two',
          macAddress: '00:11:22:33:44:52').toJson(),
      ]),
    });
    final woken = <String>[];
    await tester.pumpWidget(MaterialApp(home: SamsungTvScreen(
      initialHost: '192.168.68.52',
      autoConnect: false,
      wakeDevice: (tv) async => woken.add(tv.host),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('samsung-selected-tv-card')),
        findsOneWidget);
    expect(find.text('Kitchen Samsung'), findsNothing);
    expect(find.text('Turn on Office Samsung'), findsOneWidget);
    expect(find.text('Discover Samsung TVs'), findsNothing);
    expect(find.byKey(const ValueKey('samsung-power-toggle')),
        findsNothing);

    await tester.tap(find.byKey(
      const ValueKey('samsung-power-selected-tv')));
    await tester.pump();
    expect(woken, ['192.168.68.52']);
    expect(find.textContaining('Power-on signal sent'), findsOneWidget);
  });

  testWidgets('Samsung detail cannot act on a different saved TV',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      SamsungTvStore.key: jsonEncode([
        const SamsungTvDevice(host: '192.168.68.51',
          name: 'Kitchen Samsung', token: 'token-one').toJson(),
      ]),
    });
    await tester.pumpWidget(const MaterialApp(home: SamsungTvScreen(
      initialHost: '192.168.68.52', autoConnect: false,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Kitchen Samsung'), findsNothing);
    expect(find.byKey(const ValueKey('samsung-power-selected-tv')),
        findsNothing);
    expect(find.text('Selected TV unavailable'), findsOneWidget);
  });
}
