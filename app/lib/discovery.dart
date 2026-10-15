import 'dart:convert';
import 'dart:io';

/// Unauthenticated LAN discovery hints. NEVER treat these as a trusted pairing.
class DiscoveredDevice {
  const DiscoveredDevice({
    required this.name,
    required this.host,
    required this.platform,
    required this.version,
  });

  final String name;
  final String host;
  final String platform;
  final String version;

  static DiscoveredDevice? parse(Datagram packet) {
    final ip = packet.address.address;
    if (!isPrivateIPv4(ip)) return null;
    try {
      final decoded = jsonDecode(utf8.decode(packet.data));
      if (decoded is! Map || decoded['protocol'] != 1 ||
          decoded['port'] != 48321 ||
          decoded['name'] is! String ||
          decoded['platform'] is! String ||
          decoded['version'] is! String) {
        return null;
      }
      final name = (decoded['name'] as String).trim();
      if (name.isEmpty || name.length > 64) return null;
      return DiscoveredDevice(
        name: name,
        host: ip,
        platform: decoded['platform'] as String,
        version: decoded['version'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

bool isPrivateIPv4(String input) {
  final parts = input.split('.');
  if (parts.length != 4) return false;
  final octets = parts.map(int.tryParse).toList();
  if (octets.any((v) => v == null || v < 0 || v > 255)) return false;
  final first = octets[0]!, second = octets[1]!;
  return first == 10 || (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168);
}

/// A two-second UDP broadcast; no account, telemetry or cloud discovery.
/// Some corporate and guest Wi-Fi networks block broadcast packets.
Future<List<DiscoveredDevice>> findNearbyDevices({
  Duration duration = const Duration(seconds: 2),
  String? scanPrefix,
  String? targetIp,
  List<String>? scanPrefixes,
}) async {
  if (scanPrefix != null && !isPrivateIPv4('$scanPrefix.1')) {
    throw const FormatException('Discovery requires a private /24 prefix');
  }
  if (scanPrefixes != null &&
      (scanPrefixes.isEmpty || scanPrefixes.length > 8 ||
       scanPrefixes.any((prefix) => !isPrivateIPv4('$prefix.1')))) {
    throw const FormatException('Discovery supports up to eight private /24 ranges');
  }
  if (targetIp != null && !isPrivateIPv4(targetIp)) {
    throw const FormatException('Discovery target must be a private IPv4');
  }
  if (targetIp != null && scanPrefix != null &&
      !targetIp.startsWith('$scanPrefix.')) {
    throw const FormatException('Discovery target outside selected subnet');
  }
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  final devices = <String, DiscoveredDevice>{};
  final subscription = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    Datagram? packet;
    while ((packet = socket.receive()) != null) {
      final device = DiscoveredDevice.parse(packet!);
      if (device != null) devices[device.host] = device;
    }
  });
  try {
    final probe = utf8.encode('TAPTETHER_DISCOVER_V1');
    // Try LAN broadcast plus limited on-link unicast. Some iOS networks
    // disallow broadcast without special entitlements, but permit unicast.
    if (targetIp != null) {
      try {
        socket.send(probe, InternetAddress(targetIp), 48322);
      } on SocketException {
        // Target may have no agent or local network may be restricted.
      }
      await Future<void>.delayed(duration);
      return devices.values.toList();
    }
    try {
      socket.send(probe, InternetAddress('255.255.255.255'), 48322);
    } on SocketException {
      // Try on-link unicast next.
    }
    final prefixes = <String>{};
    if (scanPrefixes != null) {
      prefixes.addAll(scanPrefixes);
    } else if (scanPrefix != null) {
      // Scan only the selected LAN range rather than an unrelated adapter.
      prefixes.add(scanPrefix);
    } else {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address;
          if (!isPrivateIPv4(ip)) continue;
          final octets = ip.split('.');
          prefixes.add('${octets[0]}.${octets[1]}.${octets[2]}');
          // Default discovery stays small; explicit Wi-Fi subnet scanning
          // passes scanPrefixes so /23 and /22 networks are included.
          if (prefixes.length >= 2) break;
        }
        if (prefixes.length >= 2) break;
      }
    }
    for (final prefix in prefixes) {
      for (var last = 1; last <= 254; last++) {
        try {
          socket.send(probe, InternetAddress('$prefix.$last'), 48322);
        } on SocketException {
          // Continue probing other on-link hosts.
        }
      }
    }
    await Future<void>.delayed(duration);
  } finally {
    await subscription.cancel();
    socket.close();
  }
  return devices.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
}
