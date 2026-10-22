import 'dart:io';
import 'lan_scan.dart';

String? normalizeTvMac(String value) {
  final hex = value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toUpperCase();
  if (!RegExp(r'^[0-9A-F]{12}$').hasMatch(hex) ||
      hex == '000000000000' || hex == 'FFFFFFFFFFFF') {
    return null;
  }
  return List.generate(6, (i) => hex.substring(i * 2, i * 2 + 2))
      .join(':');
}

/// Bounded discovery, active /24 first, then remaining portions of real CIDR.
List<String> tvLanHosts(DetectedLanRange network, {int maxHosts = 1024}) {
  final prefixes = [network.activePrefix,
    ...network.scanPrefixes.where((p) => p != network.activePrefix)];
  final networkBase = network.cidr.split('/').first;
  final mask = network.subnetMask.split('.').map(int.parse).toList();
  final ip = network.ip.split('.').map(int.parse).toList();
  final broadcast = List.generate(4,
      (i) => ip[i] | (255 ^ mask[i])).join('.');
  final hosts = <String>[];
  for (final prefix in prefixes) {
    for (var i = 0; i <= 255; i++) {
      final host = '$prefix.$i';
      if (host == networkBase || host == broadcast || host == network.ip ||
          !lanRangeContains(network, host)) {
        continue;
      }
      hosts.add(host);
      if (hosts.length >= maxHosts) {
        return hosts;
      }
    }
  }
  return hosts;
}

/// Sends three local broadcast WOL packets. The TV must support network
/// standby / Power On with Mobile, and Wi-Fi routers must allow broadcast.
Future<void> wakeTvOnLan(String host, String macAddress) async {
  final mac = normalizeTvMac(macAddress);
  if (mac == null) {
    throw StateError('Save a valid TV MAC address to use Power On.');
  }
  final network = await detectLanRange();
  if (network == null || !lanRangeContains(network, host)) {
    throw StateError('Connect to the same Wi-Fi network as this TV.');
  }
  final stripped = mac.replaceAll(':', '');
  final bytes = <int>[
    for (var i = 0; i < 12; i += 2)
      int.parse(stripped.substring(i, i + 2), radix: 16),
  ];
  final packet = <int>[
    ...List<int>.filled(6, 255),
    for (var i = 0; i < 16; i++) ...bytes,
  ];
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    socket.broadcastEnabled = true;
    final target = InternetAddress(lanBroadcastAddress(network));
    for (var i = 0; i < 3; i++) {
      socket.send(packet, target, 9);
    }
  } finally {
    socket.close();
  }
}
