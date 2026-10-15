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
        scanRange: (prefix, {onProgress, onAgentFound, cancelled}) async {
          seenPrefixes.add(prefix);
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
    expect(network.scanPrefixes, ['192.168.20', '192.168.21']);
    expect(find.textContaining('192.168.20.0/23'), findsWidgets);
    final allSubnets = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('scan-whole-network')));
    expect(allSubnets.value, isTrue);
    await tester.tap(find.text('Start IP scan'));
    await tester.pump();
    await tester.pump();
    expect(seenPrefixes, ['192.168.20', '192.168.21']);
    expect(verifiedIps, ['192.168.21.242']);
    expect(find.text('Sandips-MBP'), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-verified-pairs')),
        findsOneWidget);
    expect(find.textContaining('Checking'), findsWidgets);

    holdSecondRange.complete();
    await tester.pumpAndSettle();
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
        scanRange: (prefix, {onProgress, onAgentFound, cancelled}) async {
          if (prefix != '192.168.21') return [];
          const host = LanHost(
            ip: '192.168.21.242',
            hostname: 'UnknownMac.local',
            openPorts: [48321],
          );
          onAgentFound?.call(host);
          return [host];
        },
        verifyPairedAgent: (_) async => null,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start IP scan'));
    await tester.pumpAndSettle();
    expect(find.text('UnknownMac.local'), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-verified-pairs')), findsNothing);
  });
}
