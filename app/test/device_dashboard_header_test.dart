import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/device_dashboard_header.dart';

void main() {
  testWidgets('icon-only scopes select network and open thermostats',
      (tester) async {
    final selected = <bool>[];
    var refreshes = 0;
    var manages = 0;
    var thermostats = 0;
    var iot = 0;
    var cameras = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DeviceDashboardHeader(
        allDevices: true, onWifi: true, locating: false,
        onScopeChanged: selected.add,
        onThermostats: () => thermostats++,
        onIot: () => iot++,
        onCameras: () => cameras++,
        onManage: () => manages++,
        onLocate: () => refreshes++,
      ),
    )));
    expect(find.byTooltip('All devices'), findsOneWidget);
    expect(find.byTooltip('On this network'), findsOneWidget);
    expect(find.byTooltip('Thermostats'), findsOneWidget);
    expect(find.byTooltip('IoT'), findsOneWidget);
    expect(find.byTooltip('Cameras'), findsOneWidget);
    expect(find.text('All Devices'), findsNothing);
    expect(find.text('On This Network'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('device-scope-network')));
    expect(selected, [false]);
    await tester.tap(find.byKey(const ValueKey('device-scope-thermostats')));
    expect(thermostats, 1);
    await tester.tap(find.byKey(const ValueKey('device-scope-iot')));
    expect(iot, 1);
    await tester.tap(find.byKey(const ValueKey('device-scope-cameras')));
    expect(cameras, 1);
    await tester.tap(find.byKey(const ValueKey('locate-saved-devices')));
    expect(refreshes, 1);
    await tester.tap(find.byKey(const ValueKey('manage-saved-devices')));
    expect(manages, 1);
  });

  testWidgets('no Wi-Fi keeps inventory and thermostat shortcut available',
      (tester) async {
    var thermostats = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DeviceDashboardHeader(
        allDevices: true, onWifi: false, locating: false,
        onScopeChanged: (_) {},
        onThermostats: () => thermostats++,
        onIot: () {},
        onCameras: () {},
        onManage: () {},
        onLocate: () => fail('No Wi-Fi scan while offline'),
      ),
    )));
    await tester.tap(find.byKey(const ValueKey('device-scope-thermostats')));
    expect(thermostats, 1);
    expect(find.byKey(const ValueKey('locate-saved-devices')), findsNothing);
  });

  testWidgets('busy network scan cannot be triggered again',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DeviceDashboardHeader(
        allDevices: false, onWifi: true, locating: true,
        onScopeChanged: (_) {},
        onThermostats: () {},
        onIot: () {},
        onCameras: () {},
        onManage: () {},
        onLocate: () => fail('Cannot duplicate a locate request'),
      ),
    )));
    expect(find.byTooltip('Locating saved devices'), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('locate-saved-devices')));
    expect(button.onPressed, isNull);
  });
}
