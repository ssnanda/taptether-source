import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/deep_port_scan.dart';
import 'package:taptether/lan_scan.dart';

void main() {
  final home = rangeFromWifi('192.168.68.101',
      '255.255.252.0')!;

  test('known LG appliance IPs can be targeted inside full /22', () {
    expect(parseDeepScanTargets(
      '192.168.68.73, 192.168.68.53 192.168.68.72', home),
      ['192.168.68.73', '192.168.68.53', '192.168.68.72']);
    expect(() => parseDeepScanTargets('8.8.8.8', home),
        throwsFormatException);
    expect(deepScanNetworkHosts(home).length, 1022);
    expect(deepScanNetworkHosts(home).first, '192.168.68.1');
    expect(deepScanNetworkHosts(home).last, '192.168.71.254');
  });

  test('bounded deep scan reports the exact open TCP ports', () async {
    final results = await scanDeepTcp(
      hosts: ['192.168.68.73'],
      network: home,
      firstPort: 78,
      lastPort: 82,
      parallelism: 2,
      probe: (host, port, timeout) async => port == 80,
    );
    expect(results.single.ip, '192.168.68.73');
    expect(results.single.checked, 5);
    expect(results.single.openPorts, [80]);
  });

  test('cancelled deep scan stops without claiming host is offline',
      () async {
    var count = 0;
    var cancelled = false;
    final result = await scanDeepTcp(
      hosts: ['192.168.68.73'],
      network: home,
      firstPort: 1,
      lastPort: 65535,
      parallelism: 1,
      cancelled: () => cancelled,
      probe: (_, _, _) async {
        count++;
        if (count == 3) cancelled = true;
        return false;
      },
    );
    expect(count, 3);
    expect(result.single.checked, 3);
    expect(result.single.openPorts, isEmpty);
  });
}
