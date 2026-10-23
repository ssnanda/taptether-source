import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/lan_scan_screen.dart';

void main() {
  testWidgets('network → IP → back keeps the same list and can inspect another',
      (tester) async {
    final network = rangeFromWifi('192.168.68.101',
        '255.255.255.0')!;
    var scans = 0;
    const washer = LanHost(ip: '192.168.68.73',
      hostname: 'Washer.local', openPorts: [80]);
    const dryer = LanHost(ip: '192.168.68.53',
      hostname: 'Dryer.local', openPorts: [443]);
    await tester.pumpWidget(MaterialApp(
      home: LanScanScreen(
        initialNetwork: network,
        scanRange: (prefix, {onProgress, onAgentFound, onProbe, cancelled,
          required int startHost, int? endHost}) async {
          scans++;
          onProgress?.call(endHost! - startHost + 1,
              endHost - startHost + 1);
          return [washer, dryer];
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start network scan'));
    await tester.pumpAndSettle();
    expect(scans, 1);
    expect(find.byKey(const ValueKey('copy-network-report')),
        findsOneWidget);

    await tester.ensureVisible(
        find.byKey(const ValueKey('scan-device-192.168.68.73')));
    await tester.tap(
        find.byKey(const ValueKey('scan-device-192.168.68.73')));
    await tester.pumpAndSettle();
    expect(find.text('Device diagnostics'), findsOneWidget);
    expect(find.text('192.168.68.73'), findsWidgets);
    expect(find.byKey(const ValueKey('copy-host-report')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-lg-checkbox')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-samsung-checkbox')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-deep-checkbox')), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Scan local network'), findsOneWidget);
    expect(scans, 1); // Back must never trigger a second network scan.
    await tester.ensureVisible(
        find.byKey(const ValueKey('scan-device-192.168.68.53')));
    await tester.tap(
        find.byKey(const ValueKey('scan-device-192.168.68.53')));
    await tester.pumpAndSettle();
    expect(find.text('192.168.68.53'), findsWidgets);
    expect(scans, 1);
  });

  testWidgets('checkboxes are available at network level', (tester) async {
    final network = rangeFromWifi('192.168.68.101',
        '255.255.252.0')!;
    await tester.pumpWidget(MaterialApp(
      home: LanScanScreen(initialNetwork: network),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scan-whole-network')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('scan-targeted-only')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('scan-vendor-lg')), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-vendor-samsung')), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-deep-all-tcp')),
        findsOneWidget);
    await tester.ensureVisible(find.byKey(
        const ValueKey('scan-targeted-only')));
    await tester.tap(find.byKey(const ValueKey('scan-targeted-only')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scan-target-ips')), findsOneWidget);
  });
}
