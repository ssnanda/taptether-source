import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/lan_scan_screen.dart';

void main() {
  test('cellular/VPN private addresses never qualify as Wi-Fi', () {
    expect(localDiscoveryTransport([ConnectivityResult.mobile]), false);
    expect(localDiscoveryTransport([ConnectivityResult.vpn]), false);
    expect(localDiscoveryTransport([ConnectivityResult.mobile,
        ConnectivityResult.vpn]), false);
    expect(localDiscoveryTransport([ConnectivityResult.none]), false);
    expect(localDiscoveryTransport([ConnectivityResult.wifi]), true);
    expect(localDiscoveryTransport([ConnectivityResult.ethernet]), true);
    expect(localDiscoveryInterface('pdp_ip0'), false);
    expect(localDiscoveryInterface('rmnet_data0'), false);
    expect(localDiscoveryInterface('utun3'), false);
    expect(localDiscoveryInterface('en0'), true);
    expect(localDiscoveryInterface('wlan0'), true);
  });

  testWidgets('cellular scan page explains why scanning is unavailable',
      (tester) async {
    var probes = 0;
    await tester.pumpWidget(MaterialApp(home: LanScanScreen(
      initialIp: '10.0.118.114',
      networkDetector: () async => null,
      scanRange: (prefix, {onProgress, onAgentFound, onProbe, cancelled,
          required startHost, endHost}) async {
        probes++;
        return [];
      },
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cellular networks are not scanned'),
        findsOneWidget);
    final scan = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start IP scan'));
    expect(scan.onPressed, isNull);
    expect(probes, 0);
  });

  testWidgets('Wi-Fi scan remains available with a verified LAN range',
      (tester) async {
    final range = rangeFromWifi('192.168.68.51', '255.255.255.0')!;
    var probes = 0;
    await tester.pumpWidget(MaterialApp(home: LanScanScreen(
      networkDetector: () async => range,
      scanRange: (prefix, {onProgress, onAgentFound, onProbe, cancelled,
          required startHost, endHost}) async {
        probes++;
        final total = (endHost ?? 254) - startHost + 1;
        onProgress?.call(total, total);
        return [];
      },
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cellular networks are not scanned'),
        findsNothing);
    final scan = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Start IP scan'));
    expect(scan.onPressed, isNotNull);
    await tester.tap(find.text('Start IP scan'));
    await tester.pumpAndSettle();
    expect(probes, 1);
  });
}
