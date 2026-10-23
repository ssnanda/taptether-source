import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/lan_scan_screen.dart';

void main() {
  testWidgets('Scan IPs immediately recognizes paired computer on /23',
      (tester) async {
    final holdSecondRange = Completer<void>();
    final seenPrefixes = <String>[];
    final visitedBounds = <String>[];
    final verifiedIps = <String>[];
    const newHost = LanHost(
      ip: '192.168.21.242',
      hostname: 'Sandips-MBP.local',
      openPorts: [48321],
      platform: 'darwin',
    );
    final network = rangeFromWifi(
      '192.168.21.252', '255.255.254.0',
    )!;
    await tester.pumpWidget(MaterialApp(
      home: LanScanScreen(
        initialNetwork: network,
        scanRange: (prefix, {
          onProgress, onAgentFound, onProbe, cancelled,
          required int startHost, endHost,
        }) async {
          seenPrefixes.add(prefix);
          visitedBounds.add('$prefix:$startHost-$endHost');
          onProbe?.call('$prefix.242', const []);
          if (prefix == '192.168.20') {
            return const [];
          }
          onAgentFound?.call(newHost);
          await holdSecondRange.future;
          return [newHost];
        },
        verifyPairedAgent: (ip) async {
          verifiedIps.add(ip);
          return 'Sandips-MBP';
        },
      ),
    ));

    await tester.pumpAndSettle();
    expect(network.scanPrefixes.toSet(),
        {'192.168.20', '192.168.21'});
    expect(find.textContaining('192.168.20.0/23'), findsWidgets);
    final allSubnets = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('scan-whole-network')));
    expect(allSubnets.value, isTrue);
    await tester.scrollUntilVisible(
        find.text('Start network scan'), 220, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Start network scan'));
    await tester.pump();
    await tester.pump();
    // Active Wi-Fi /24 is intentionally scanned first; the verifier runs
    // before that prefix finishes and before the second half is searched.
    expect(seenPrefixes, ['192.168.21']);
    expect(verifiedIps, ['192.168.21.242']);
    // The result cards are below the fold on Flutter's test-sized phone.
    // Scroll while the scan is still waiting for the rest of the subnet.
    await tester.scrollUntilVisible(
        find.text('Sandips-MBP'), 190, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Sandips-MBP'), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-verified-pairs')),
        findsOneWidget);
    // Scrolling the lazy list can dispose the off-screen progress label.
    // The held second range is the reliable proof that scanning continues.
    expect(holdSecondRange.isCompleted, isFalse);

    holdSecondRange.complete();
    await tester.pumpAndSettle();
    expect(seenPrefixes.toSet(), {'192.168.20', '192.168.21'});
    expect(visitedBounds.toSet(),
        {'192.168.21:0-254', '192.168.20:1-255'});
    expect(find.textContaining('paired computer(s) verified'), findsOneWidget);
  });

  testWidgets('Unverified TCP hosts do not claim to be paired',
      (tester) async {
    final network = rangeFromWifi(
      '192.168.21.252', '255.255.254.0',
    )!;
    await tester.pumpWidget(MaterialApp(
      home: LanScanScreen(
        initialNetwork: network,
        scanRange: (prefix, {
          onProgress, onAgentFound, onProbe, cancelled,
          required int startHost, endHost,
        }) async {
          if (prefix != '192.168.21') return [];
          const host = LanHost(
            ip: '192.168.21.242',
            hostname: 'UnknownMac.local',
            openPorts: [48321],
          );
          onProbe?.call(host.ip, host.openPorts);
          onAgentFound?.call(host);
          return [host];
        },
        verifyPairedAgent: (_) async => null,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Start network scan'), 220, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Start network scan'));
    await tester.pumpAndSettle();
    expect(find.text('UnknownMac.local'), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-verified-pairs')), findsNothing);
  });
}
