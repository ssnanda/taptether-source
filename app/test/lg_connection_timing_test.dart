import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lg_connection_timing.dart';
import 'package:taptether/lg_webos_client.dart';

void main() {
  final first = DateTime(2026, 11, 2, 17, 17, 0);

  test('records powered on, finding, found and authenticated connection', () {
    final woke = const LgConnectionTiming().powerOn(first);
    final finding = woke.finding(first.add(const Duration(seconds: 10)));
    final found = finding.found(first.add(const Duration(seconds: 43)));
    final connected = found.connected(first.add(const Duration(seconds: 57)));

    expect(finding.isActiveWake(first.add(const Duration(seconds: 15))), true);
    expect(found.lastPowerToFoundSeconds, 43);
    expect(connected.lastPowerToConnectedSeconds, 57);
    expect(connected.lastPowerToFoundSeconds, 43);
    expect(connected.isActiveWake(first.add(const Duration(seconds: 58))), false);
    expect(connected.lastConnectedMs,
        first.add(const Duration(seconds: 57)).millisecondsSinceEpoch);
    expect(LgConnectionTiming.fromJson(connected.toJson()).toJson(),
        connected.toJson());
  });

  test('a later wake resets cycle without losing historical connection', () {
    final connected = const LgConnectionTiming().powerOn(first)
        .found(first.add(const Duration(seconds: 12)))
        .connected(first.add(const Duration(seconds: 19)));
    final next = connected.powerOn(first.add(const Duration(hours: 3)));
    expect(next.connectedDuringWakeMs, isNull);
    expect(next.foundDuringWakeMs, isNull);
    expect(next.lastConnectedMs, connected.lastConnectedMs);
    expect(next.lastPowerToConnectedSeconds, 19);
  });

  test('normal reconnect records last connected without fabricating wake', () {
    final t = const LgConnectionTiming().connected(first);
    expect(t.lastConnectedMs, first.millisecondsSinceEpoch);
    expect(t.lastPowerToConnectedSeconds, isNull);
    expect(t.lastPoweredOnMs, isNull);
  });

  test('format elapsed durations and local time safely', () {
    expect(lgElapsed(const Duration(seconds: 8)), '00:08');
    expect(lgElapsed(const Duration(minutes: 2, seconds: 4)), '02:04');
    expect(lgElapsed(const Duration(hours: 1, minutes: 3, seconds: 4)),
        '1:03:04');
    expect(lgClock(null), 'Never');
    expect(lgClock(0, fromEpoch: (_) => first, now: first), '5:17 PM');
    expect(lgClock(0, fromEpoch: (_) => first,
        now: first.add(const Duration(days: 1))), 'Yesterday 5:17 PM');
  });

  test('TV TLS pin is a stable timing key across DHCP IP changes', () {
    final store = LgConnectionTimingStore();
    const firstHost = LgTvDevice(
        host: '192.168.68.85', name: 'Family Room TV',
        tlsPin: 'abcd', clientKey: 'secret');
    const newHost = LgTvDevice(
        host: '192.168.68.77', name: 'Family Room TV',
        tlsPin: 'ABCD', clientKey: 'secret');
    expect(store.identity(firstHost), store.identity(newHost));
  });
}
