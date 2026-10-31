import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/device_dashboard_header.dart';

void main() {
  testWidgets('all devices is the default compact inventory scope',
      (tester) async {
    final selected = <bool>[];
    var refreshes = 0;
    var manages = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DeviceDashboardHeader(
        allDevices: true, onWifi: true, locating: false,
        onScopeChanged: selected.add,
        onManage: () => manages++,
        onLocate: () => refreshes++,
      ),
    )));
    expect(find.text('All Devices'), findsOneWidget);
    expect(find.text('On This Network'), findsOneWidget);
    expect(find.text('My Devices'), findsNothing);
    expect(find.text('Other'), findsNothing);
    expect(find.text('Show offline'), findsNothing);
    expect(find.textContaining('0 computers'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('device-scope-network')));
    expect(selected, [false]);
    await tester.tap(find.byKey(const ValueKey('locate-saved-devices')));
    expect(refreshes, 1);
    await tester.tap(find.byKey(const ValueKey('manage-saved-devices')));
    expect(manages, 1);
  });

  testWidgets('offline scope still supports All Devices without a scan',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DeviceDashboardHeader(
        allDevices: true, onWifi: false, locating: false,
        onScopeChanged: (_) {},
        onManage: () {},
        onLocate: () => fail('No Wi-Fi scanning while offline'),
      ),
    )));
    expect(find.text('All Devices'), findsOneWidget);
    expect(find.text('On This Network'), findsOneWidget);
    expect(find.byKey(const ValueKey('manage-saved-devices')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('locate-saved-devices')), findsNothing);
  });

  testWidgets('busy network scan cannot be triggered again',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DeviceDashboardHeader(
        allDevices: false, onWifi: true, locating: true,
        onScopeChanged: (_) {},
        onManage: () {},
        onLocate: () => fail('Cannot duplicate a Locate request'),
      ),
    )));
    expect(find.byTooltip('Locating saved devices'), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('locate-saved-devices')),
    );
    expect(button.onPressed, isNull);
  });
}
