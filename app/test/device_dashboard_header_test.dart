import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/device_dashboard_header.dart';

void main() {
  testWidgets('one actionable Locate button and compact device controls',
      (tester) async {
    var locateCount = 0;
    var manageCount = 0;
    var offline = true;
    String? chosenLocation;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(
        child: DeviceDashboardHeader(
          showFilters: true,
          locationFilter: 'all',
          detectedLocation: 'home',
          showOffline: true,
          onlineComputerCount: 1,
          onlineTvCount: 2,
          locating: false,
          onManage: () => manageCount++,
          onLocationChanged: (location) => chosenLocation = location,
          onShowOfflineChanged: (value) => offline = value,
          onLocate: () => locateCount++,
        ),
      )),
    ));

    expect(find.text('My Devices'), findsOneWidget);
    expect(find.text('1 computer · 2 TVs'), findsOneWidget);
    expect(find.byTooltip('Check device status'), findsNothing);
    expect(find.byKey(const ValueKey('locate-saved-devices')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('locate-saved-devices')));
    expect(locateCount, 1);
    await tester.tap(find.byKey(const ValueKey('manage-saved-devices')));
    expect(manageCount, 1);
    await tester.tap(find.byKey(const ValueKey('show-offline-devices')));
    expect(offline, isFalse);
    await tester.tap(find.byKey(const ValueKey('device-location-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home').last);
    await tester.pumpAndSettle();
    expect(chosenLocation, 'home');
  });

  testWidgets('Locate shows progress only for active manual request',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DeviceDashboardHeader(
        showFilters: true,
        locationFilter: 'all',
        detectedLocation: null,
        showOffline: false,
        onlineComputerCount: 0,
        onlineTvCount: 0,
        locating: true,
        onManage: () {},
        onLocationChanged: (_) {},
        onShowOfflineChanged: (_) {},
        onLocate: () => fail('Cannot start duplicate Locate'),
      )),
    ));
    expect(find.byTooltip('Locating saved devices'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('locate-saved-devices')));
    expect(button.onPressed, isNull);
  });

  testWidgets('empty dashboard keeps Manage and hides network filters',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DeviceDashboardHeader(
        showFilters: false,
        locationFilter: 'all',
        detectedLocation: null,
        showOffline: true,
        onlineComputerCount: 0,
        onlineTvCount: 0,
        locating: false,
        onManage: () {},
        onLocationChanged: (_) {},
        onShowOfflineChanged: (_) {},
        onLocate: () {},
      )),
    ));
    expect(find.text('My Devices'), findsOneWidget);
    expect(find.byKey(const ValueKey('manage-saved-devices')), findsOneWidget);
    expect(find.byKey(const ValueKey('locate-saved-devices')), findsNothing);
    expect(find.text('Show offline'), findsNothing);
  });
}
