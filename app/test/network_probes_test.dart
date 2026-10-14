import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/lan_scan.dart';
import 'package:taptether/network_probes.dart';

void main() {
  test('mDNS A response supplies an on-link computer name and IPv4', () {
    final response = <int>[
      0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0,
      7, ...ascii.encode('macbook'),
      5, ...ascii.encode('local'), 0,
      0, 1, 0, 1, 0, 0, 0, 30, 0, 4,
      192, 168, 68, 87,
    ];
    expect(parseMdnsAddresses(response),
        {'192.168.68.87': 'macbook.local'});
    expect(parseMdnsAddresses([0, 0, 0]), isEmpty);
    // A malformed pointer cycle must not loop forever.
    expect(parseMdnsAddresses(<int>[
      0, 0, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xc0, 12,
    ]), isEmpty);
  });

  test('SSDP responses are best-effort local hints, not pairing', () {
    final packet = ascii.encode(
        'HTTP/1.1 200 OK\r\nSERVER: Printer Bridge\r\n\r\n');
    final hint = parseSsdpHost('192.168.68.45', packet);
    expect(hint?.name, 'Printer Bridge');
    expect(hint?.ip, '192.168.68.45');
    expect(parseSsdpHost('8.8.8.8', packet), isNull);
    expect(parseSsdpHost('192.168.68.45',
        ascii.encode('garbage')), isNull);
  });

  test('neighbor merge adds closed-port devices without duplicate IPs', () {
    final result = mergeLanNeighbors([
      const LanHost(ip: '192.168.68.45',
          hostname: '192.168.68.45', openPorts: [80]),
    ], [
      const LanProbeHost('192.168.68.45', 'printer.local', 'mDNS'),
      const LanProbeHost('192.168.68.87', 'macbook.local', 'mDNS'),
      const LanProbeHost('192.168.69.80', 'outside.local', 'mDNS'),
    ], '192.168.68');
    expect(result.length, 2);
    expect(result.first.displayName, 'printer.local');
    expect(result.first.openPorts, [80]);
    expect(result.last.displayName, 'macbook.local');
    expect(result.last.openPorts, isEmpty);
  });
}
