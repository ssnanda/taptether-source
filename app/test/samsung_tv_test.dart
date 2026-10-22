import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_compact_remote.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/samsung_tv_client.dart';
import 'package:taptether/tv_lan_utils.dart';

class FakeSamsungRemote extends SamsungTvClient {
  FakeSamsungRemote() : super(const SamsungTvDevice(
    host: '192.168.68.62', name: 'Office Display', token: 'paired'));
  int clicks = 0;
  @override
  bool get connected => true;
  @override
  Future<List<({String id, String title})>> apps() async => [
    (id: '111299001912', title: 'YouTube'),
  ];
  @override
  Future<String?> foregroundApp() async => '111299001912';
  @override
  Future<int?> volumeLevel() async => null;
  @override
  Future<void> pointerClick() async { clicks++; }
  @override
  Future<void> pointerMove(int dx, int dy) async {}
  @override
  Future<void> button(String name) async {}
  @override
  Future<void> launchApp(String appId) async {}
}

void main() {
  test('Only Samsung Smart View REST identity qualifies for discovery', () {
    final tv = samsungDeviceFromInfo('192.168.68.62', {
      'name': 'Samsung',
      'device': {
        'type': 'Samsung SmartTV',
        'modelName': 'QN55',
        'id': 'uuid:samsung-office',
        'wifiMac': 'aa-bb-cc-dd-ee-ff',
      },
    });
    expect(tv, isNotNull);
    expect(tv!.deviceId, 'uuid:samsung-office');
    expect(tv.macAddress, 'AA:BB:CC:DD:EE:FF');
    expect(tv.model, 'QN55');
    expect(samsungDeviceFromInfo('192.168.68.81', {
      'device': {'type': 'MacBook Pro'},
    }), isNull);
    expect(samsungDeviceFromInfo('192.168.68.90', {}), isNull);
    expect(samsungDeviceFromInfo('192.168.68.90', {
      'device': {'type': 'SmartTV'},
    }), isNull);
  });

  test('TV discovery stays inside the active private Wi-Fi CIDR', () {
    final lan = rangeFromWifi('192.168.68.70', '255.255.252.0')!;
    final hosts = tvLanHosts(lan);
    expect(hosts, contains('192.168.68.62'));
    expect(hosts, contains('192.168.71.254'));
    expect(hosts, isNot(contains('192.168.68.0')));
    expect(hosts, isNot(contains('192.168.71.255')));
    expect(hosts, isNot(contains('192.168.68.70')));
    expect(hosts, isNot(contains('192.168.72.1')));
    expect(hosts.length, 1021);
  });

  test('Samsung pairing and nickname serialize without losing credentials', () {
    const tv = SamsungTvDevice(
      host: '192.168.68.84', name: 'Office Display',
      token: 'sample-token', deviceId: 'uuid:tizen1',
      tlsPin: 'CERTPIN', macAddress: 'AA:BB:CC:DD:EE:FF',
      location: 'office',
    );
    final reread = SamsungTvDevice.fromJson(
        Map<String, dynamic>.from(tv.toJson()));
    expect(reread.name, 'Office Display');
    expect(reread.token, 'sample-token');
    expect(reread.macAddress, 'AA:BB:CC:DD:EE:FF');
    expect(reread.location, 'office');
    expect(reread.copyWith(host: '192.168.1.84').deviceId,
        'uuid:tizen1');
    expect(normalizeTvMac('aa:bb:cc:dd:ee:ff'),
        'AA:BB:CC:DD:EE:FF');
  });

  testWidgets('Samsung shares no-scroll touchpad and optional arrow dialog',
      (tester) async {
    final client = FakeSamsungRemote();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(
        width: 390, height: 600,
        child: LgCompactRemote(
          client: client, device: client.device, onError: (_) {}),
      )),
    ));
    await tester.pump();
    expect(find.text('Swipe for arrows · Tap for OK'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(find.text('Touchpad'), findsOneWidget);
    await tester.tap(find.text('Touchpad'));
    await tester.pump();
    expect(client.clicks, 1);
    await tester.tap(find.byTooltip('Arrows and OK'));
    await tester.pumpAndSettle();
    expect(find.text('Navigation'), findsOneWidget);
  });
}
