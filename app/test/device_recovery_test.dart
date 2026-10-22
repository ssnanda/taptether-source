import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/computer_store.dart';
import 'package:taptether/device_recovery.dart';
import 'package:taptether/discovery.dart';
import 'package:taptether/lan_scan.dart';

void main() {
  const fingerprint = 'ABCDEF0123456789ABCDEF0123456789'
      'ABCDEF0123456789ABCDEF0123456789';
  SavedComputer saved(String id, String ip, {String name = 'Sandips-MBP'}) =>
      SavedComputer(
        id: id, name: name, host: ip, deviceId: List.filled(32, 'a').join(),
        token: '', fingerprint: fingerprint,
        platform: 'darwin', location: 'home',
        customName: true,
      );

  test('a /23 contains both halves and maps a roaming Mac', () {
    final network = rangeFromWifi(
        '192.168.21.252', '255.255.254.0')!;
    expect(network.cidr, '192.168.20.0/23');
    expect(network.scanPrefixes.toSet(),
        {'192.168.20', '192.168.21'});
    expect(lanRangeContains(network, '192.168.21.242'), isTrue);
    expect(lanRangeContains(network, '192.168.20.1'), isTrue);
    expect(lanRangeContains(network, '192.168.1.86'), isFalse);
    expect(lanRangeContains(network, '192.168.68.77'), isFalse);
    final old = saved('mac', '192.168.68.77');
    final suggestions = recoveryCandidates(old, network, const [
      DiscoveredDevice(name: 'Sandips-MBP', host: '192.168.21.242',
          platform: 'darwin', version: '0.6.12'),
      DiscoveredDevice(name: 'Sandips-MBP', host: '192.168.1.86',
          platform: 'darwin', version: '0.6.12'),
      DiscoveredDevice(name: 'Another Mac', host: '192.168.20.15',
          platform: 'darwin', version: '0.6.12'),
    ]);
    expect(suggestions, ['192.168.21.242', '192.168.20.15']);
    final updated = movedDevice(old, suggestions.first,
        currentLocation: 'office');
    expect(updated.id, old.id);
    expect(updated.host, '192.168.21.242');
    expect(updated.fingerprint, old.fingerprint);
    expect(updated.deviceId, old.deviceId);
    expect(updated.name, 'Sandips-MBP');
    expect(updated.customName, isTrue);
    expect(updated.location, 'office');
  });

  test('same IP or hostname is never sufficient to identify a paired Mac', () {
    final mac = saved('mac', '192.168.21.242');
    final imposter = SavedComputer(
      id: 'other', name: mac.name, host: mac.host,
      token: 'different', fingerprint: List.filled(64, 'F').join(),
    );
    expect(samePairedAgent(mac, imposter), isFalse);
    expect(samePairedAgent(mac, saved('roamed', '192.168.1.86')), isTrue);
    expect(() => movedDevice(mac, '8.8.8.8'), throwsFormatException);
  });

  test('only safe local DNS names are considered for agent recovery', () {
    expect(localAgentDnsName('Sandips-MBP'), 'sandips-mbp.local');
    expect(localAgentDnsName('Sandips-MBP.local'), 'sandips-mbp.local');
    expect(localAgentDnsName('My MacBook'), isNull);
    expect(localAgentDnsName('example.com'), isNull);
    expect(localAgentDnsName('192.168.68.86'), isNull);
    expect(localAgentDnsName('bad/hostname'), isNull);
  });

  test('DNS recovery keeps only addresses on current Wi-Fi CIDR', () async {
    final network = rangeFromWifi(
        '192.168.68.100', '255.255.252.0')!;
    final addresses = await resolveSavedAgentLanAddresses(
        saved('mac', '192.168.68.77'), network,
        lookup: (host) async {
          expect(host, 'sandips-mbp.local');
          return [
            InternetAddress('192.168.69.50'),
            InternetAddress('192.168.72.50'),
            InternetAddress('192.168.69.50'),
            InternetAddress('8.8.8.8'),
          ];
        });
    expect(addresses, ['192.168.69.50']);
  });

  test('TCP recovery probes both sides of the current /23', () {
    final network = rangeFromWifi(
        '192.168.21.252', '255.255.254.0')!;
    final probes = agentTcpProbeAddresses(network);
    expect(probes, contains('192.168.21.242'));
    expect(probes, contains('192.168.20.1'));
    expect(probes, contains('192.168.21.0'));
    expect(probes, contains('192.168.20.255'));
    expect(probes, isNot(contains('192.168.20.0')));
    expect(probes, isNot(contains('192.168.21.255')));
    expect(probes, isNot(contains('192.168.1.86')));
    expect(probes, isNot(contains('192.168.68.77')));
    expect(probes.length, 510);
    expect(agentTcpProbeAddresses(network, maxAddresses: 10).length, 10);
  });

  test('TCP recovery cannot sweep an unbounded larger subnet', () {
    final network = rangeFromWifi(
        '192.168.21.252', '255.255.240.0')!;
    expect(agentTcpProbeAddresses(network).length, lessThanOrEqualTo(1024));
    expect(agentTcpProbeAddresses(network), contains('192.168.21.242'));
  });

  test('recovery never suggests a host outside the detected subnet', () {
    final network = rangeFromWifi(
        '192.168.21.252', '255.255.254.0')!;
    expect(recoveryCandidates(saved('mac', '192.168.68.77'), network,
      const [DiscoveredDevice(name: 'Mac', host: '192.168.1.155',
        platform: 'darwin', version: '0.6.12')]), isEmpty);
  });
}
