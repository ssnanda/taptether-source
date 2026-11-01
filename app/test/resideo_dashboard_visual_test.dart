import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/resideo_api.dart';
import 'package:taptether/resideo_local_vault.dart';
import 'package:taptether/resideo_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Thermostat dashboard matches grouped snapshot layout',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    const storage = FlutterSecureStorage();
    final connection = ResideoConnection(storage: storage);
    await connection.save(const ResideoCredentials(
      apiKey: 'EXAMPLE_KEY',
      apiSecret: 'EXAMPLE_SECRET',
      accessToken: 'EXAMPLE_ACCESS',
      redirectUri: ResideoConnection.defaultRedirect,
    ));
    final vault = ResideoLocalVault(storage: storage);
    final devices = <ResideoDevice>[];
    for (final room in ['Upstairs', 'Main', 'Basement']) {
      devices.add(ResideoDevice.fromApi({
        'deviceID': 'DEVICE-$room',
        'deviceClass': 'Thermostat',
        'userDefinedDeviceName': room,
        'isAlive': true,
        'units': 'Fahrenheit',
        'indoorTemperature': 70,
        'indoorHumidity': 54,
        'outdoorTemperature': 57,
        'allowedModes': ['Off', 'Heat', 'Cool', 'Auto'],
        'changeableValues': {
          'mode': 'Cool',
          'heatSetpoint': 66,
          'coolSetpoint': 72,
        },
        'settings': {
          'fan': {
            'allowedModes': ['Auto', 'Circulate'],
            'changeableValues': {'mode': 'Auto'},
          },
        },
      }, '9318', '9318')!);
    }
    await vault.writeCache({
      'checkedAt': DateTime.now().toUtc().toIso8601String(),
      'devices': devices.map((d) => d.toCacheRecord()).toList(),
    });
    await connection.cachedDevices();

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    await tester.pumpWidget(const MaterialApp(
      home: ResideoScreen(refreshOnOpen: false)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('resideo-summary-banner')), findsOneWidget);
    expect(find.byKey(const ValueKey('resideo-summary-count')), findsOneWidget);
    expect(find.text('3 Thermostats'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('resideo-filter-9318')), findsOneWidget);
    expect(find.byKey(const ValueKey('resideo-group-toggle-9318')), findsOneWidget);
    expect(find.byKey(const ValueKey('resideo-customize')), findsOneWidget);
    expect(find.byKey(const ValueKey('resideo-bulk-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('resideo-voice-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('resideo-card-9318:DEVICE-Upstairs')),
      findsOneWidget);
    expect(find.byKey(const ValueKey(
      'resideo-increase-9318:DEVICE-Upstairs-cool')), findsOneWidget);
    expect(find.text('Cooling'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('resideo-group-toggle-9318')));
    await tester.pump();
    expect(find.byKey(const ValueKey('resideo-card-9318:DEVICE-Upstairs')),
      findsNothing);
  });
}
