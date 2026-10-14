import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/discovery.dart';

void main() {
  test('scanner accepts only RFC1918 /24 prefixes', () {
    for (final prefix in ['192.168.68', '10.4.3', '172.16.0',
                         '172.31.255']) {
      expect(validPrivate24Prefix(prefix), isTrue, reason: prefix);
    }
    for (final prefix in ['8.8.8', '172.32.0', '192.168',
                         '192.168.68.1', '', '169.254.1']) {
      expect(validPrivate24Prefix(prefix), isFalse, reason: prefix);
    }
    expect(prefixFromIp('192.168.68.87'), '192.168.68');
    expect(prefixFromIp('8.8.8.8'), isNull);
  });

  test('Wi-Fi masks detect /22 across four 192.168.x windows', () {
    final range = rangeFromWifi('192.168.68.101', '255.255.252.0')!;
    expect(range.cidr, '192.168.68.0/22');
    expect(range.activePrefix, '192.168.68');
    expect(range.scanPrefixes.toSet(),
        {'192.168.68', '192.168.69', '192.168.70', '192.168.71'});
    expect(lanRangeContains(range, '192.168.71.255'), isTrue);
    expect(lanRangeContains(range, '192.168.72.2'), isFalse);
  });

  test('subnet detection accepts private office IPs but rejects bad masks', () {
    final office = rangeFromWifi('10.20.30.13', '255.255.255.0')!;
    expect(office.cidr, '10.20.30.0/24');
    expect(office.scanPrefixes, ['10.20.30']);
    expect(rangeFromWifi('10.0.0.5', '255.0.255.0'), isNull);
    expect(rangeFromWifi('8.8.8.8', '255.255.255.0'), isNull);
  });

  test('large private subnet scans remain bounded', () {
    final lan = rangeFromWifi('10.50.10.22', '255.255.0.0')!;
    expect(lan.cidr, '10.50.0.0/16');
    expect(lan.scanPrefixes.length, 16);
    expect(lan.scanPrefixes.first, '10.50.10');
  });

  test('service hints derive from observed open ports only', () {
    expect(const LanHost(
      ip: '192.168.68.87', hostname: 'mac.local',
      openPorts: [48321, 22],
    ).deviceHint, 'TapTether agent (likely)');
    expect(const LanHost(
      ip: '192.168.68.88', hostname: 'nas.local',
      openPorts: [445],
    ).deviceHint, 'File sharing / computer');
  });

  test('unresolved host uses device type title and only one IP', () {
    const web = LanHost(
      ip: '192.168.68.1', hostname: '192.168.68.1',
      openPorts: [80, 443],
    );
    expect(web.displayName, 'Web-enabled device');
    expect(web.scanSubtitle, contains('IP: 192.168.68.1'));
    expect('Web-enabled device ${web.scanSubtitle}'
        .split('192.168.68.1').length, 2);
    expect(web.scanSubtitle, contains('TCP: 80, 443'));

    const ssh = LanHost(
      ip: '192.168.68.86', hostname: '192.168.68.86',
      openPorts: [22],
    );
    expect(ssh.displayName, 'SSH-enabled computer / server');
    expect(ssh.scanSubtitle, 'IP: 192.168.68.86\\nTCP: 22');

    const named = LanHost(
      ip: '192.168.68.77', hostname: 'Sandips-MacBook.local',
      openPorts: [22],
    );
    expect(named.displayName, 'Sandips-MacBook.local');
    expect(named.scanSubtitle, contains('SSH-enabled computer'));
    expect(named.scanSubtitle, contains('IP: 192.168.68.77'));
  });

  test('UDP agent discovery can add Mac missed by TCP-only scan', () {
    final hosts = mergeDiscoveredAgents(
      [
        const LanHost(ip: '192.168.68.87',
            hostname: '192.168.68.87', openPorts: [22, 48321]),
      ],
      [
        const DiscoveredDevice(
          name: 'Sandips-MacBook',
          host: '192.168.68.77',
          platform: 'darwin',
          version: '0.6.9',
        ),
        const DiscoveredDevice(
          name: 'Sandbox',
          host: '192.168.69.2',
          platform: 'linux',
          version: '0.6.9',
        ),
      ],
      '192.168.68',
    );
    expect(hosts.length, 2);
    expect(hosts.first.ip, '192.168.68.77');
    expect(hosts.first.displayName, 'Sandips-MacBook');
    expect(hosts.first.deviceType, 'Mac · TapTether agent (unverified)');
    expect(hosts.first.scanSubtitle, contains('IP: 192.168.68.77'));
    expect(hosts.first.openPorts, isEmpty);
    expect(hosts.first.agentAnnounced, isTrue);
    expect(hosts.last.ip, '192.168.68.87');
  });

  test('UDP name enriches, never duplicates the TCP device row', () {
    final merged = mergeDiscoveredAgents(
      [const LanHost(
        ip: '192.168.68.77', hostname: '192.168.68.77',
        openPorts: [22, 48321],
      )],
      [const DiscoveredDevice(
        name: 'MacBook Pro',
        host: '192.168.68.77',
        platform: 'darwin', version: '0.6.9',
      )],
      '192.168.68',
    );
    expect(merged.length, 1);
    expect(merged.single.displayName, 'MacBook Pro');
    expect(merged.single.openPorts, [22, 48321]);
    expect(merged.single.scanSubtitle.split('192.168.68.77').length, 2);
  });

  test('manual check rejects public addresses before probing', () async {
    await expectLater(checkPrivateLanIp('8.8.8.8'),
        throwsFormatException);
    await expectLater(checkPrivateLanIp('192.168.68'),
        throwsFormatException);
    await expectLater(findNearbyDevices(targetIp: '8.8.8.8'),
        throwsFormatException);
    await expectLater(findNearbyDevices(scanPrefix: '8.8.8'),
        throwsFormatException);
    await expectLater(findNearbyDevices(
        targetIp: '192.168.69.77', scanPrefix: '192.168.68'),
        throwsFormatException);
  });

  test('invalid scan target fails before network access', () async {
    await expectLater(scanPrivate24('8.8.8'), throwsFormatException);
    await expectLater(scanPrivate24('192.168.68', parallelism: 200),
        throwsFormatException);
  });
}
