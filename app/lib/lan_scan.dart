import 'dart:async';
import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

import 'discovery.dart';

/// Non-invasive, on-demand TCP discovery across one private /24 only.
/// Mobile operating systems do not generally expose neighbor ARP/MAC records.
class LanHost {
  const LanHost({
    required this.ip,
    required this.hostname,
    required this.openPorts,
    this.macAddress,
  });
  final String ip;
  final String hostname;
  final List<int> openPorts;
  final String? macAddress;

  String get deviceHint {
    if (openPorts.contains(48321)) return 'TapTether agent (likely)';
    if (openPorts.contains(3389)) return 'Remote Desktop device';
    if (openPorts.contains(445)) return 'File sharing / computer';
    if (openPorts.contains(22)) return 'SSH-enabled computer or server';
    if (openPorts.contains(80) || openPorts.contains(443)) {
      return 'Web-enabled device';
    }
    return 'Network device';
  }
}

const lanScanPorts = <int>[48321, 22, 80, 443, 445, 3389];

bool validPrivate24Prefix(String prefix) =>
    isPrivateIPv4('${prefix.trim()}.1');

String? prefixFromIp(String ip) {
  if (!isPrivateIPv4(ip)) return null;
  return ip.split('.').take(3).join('.');
}


class DetectedLanRange {
  const DetectedLanRange({
    required this.ip,
    required this.subnetMask,
    required this.cidr,
    required this.activePrefix,
    required this.scanPrefixes,
    this.ssid,
  });
  final String ip;
  final String subnetMask;
  final String cidr;
  final String activePrefix;
  final List<String> scanPrefixes;
  final String? ssid;
}

int? _ipv4Number(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return null;
  var result = 0;
  for (final item in parts) {
    final n = int.tryParse(item);
    if (n == null || n < 0 || n > 255) return null;
    result = (result << 8) | n;
  }
  return result;
}

String _formatIpv4(int value) =>
    [24, 16, 8, 0].map((shift) => (value >> shift) & 255).join('.');

/// Determines the real CIDR; scanners remain bounded to one /24 at a time.
/// On /22 or larger LANs the user can choose a neighboring /24 window.
DetectedLanRange? rangeFromWifi(String ip, String mask, {String? ssid}) {
  if (!isPrivateIPv4(ip)) return null;
  final address = _ipv4Number(ip), subnet = _ipv4Number(mask);
  if (address == null || subnet == null || subnet == 0) return null;
  final hostBits = (~subnet) & 0xffffffff;
  // A valid subnet has contiguous high bits, then contiguous host bits.
  if ((hostBits & (hostBits + 1)) != 0) return null;
  final network = address & subnet;
  final broadcast = network | hostBits;
  final active = prefixFromIp(ip)!;
  final base24 = network >> 8, last24 = broadcast >> 8;
  final current = address >> 8;
  final prefixes = <String>[active];
  // At most 16 selectable /24 slices, not an unbounded scan.
  for (var distance = 1; prefixes.length < 16 &&
      (current - distance >= base24 || current + distance <= last24);
      distance++) {
    for (final offset in [-distance, distance]) {
      final selected = current + offset;
      if (selected < base24 || selected > last24) continue;
      prefixes.add(_formatIpv4(selected << 8).split('.').take(3).join('.'));
      if (prefixes.length == 16) break;
    }
  }
  return DetectedLanRange(
    ip: ip,
    subnetMask: mask,
    cidr: _formatIpv4(network) + '/' + (32 - hostBits.bitLength).toString(),
    activePrefix: active,
    scanPrefixes: prefixes,
    ssid: ssid,
  );
}

/// True only for a private IP on the detected subnet, including /22.
/// Used for current-network device grouping, not authentication.
bool lanRangeContains(DetectedLanRange range, String ip) {
  if (!isPrivateIPv4(ip)) return false;
  final addr = _ipv4Number(ip);
  final local = _ipv4Number(range.ip);
  final mask = _ipv4Number(range.subnetMask);
  return addr != null && local != null && mask != null &&
      (addr & mask) == (local & mask);
}

/// Return the current phone Wi-Fi CIDR, not a remembered host's old IP.
/// SSID is optional because iOS may withhold it without Wi-Fi entitlements.
Future<DetectedLanRange?> detectLanRange() async {
  try {
    final info = NetworkInfo();
    final ip = await info.getWifiIP();
    final mask = await info.getWifiSubmask();
    if (ip != null && mask != null) {
      final range = rangeFromWifi(ip, mask, ssid: await info.getWifiName());
      if (range != null) return range;
    }
  } catch (_) {
    // Platform Wi-Fi data unavailable or privacy restricted.
  }
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (isPrivateIPv4(address.address)) {
          // Netmask unknown: a conservative /24 window, not the router CIDR.
          return rangeFromWifi(address.address, '255.255.255.0');
        }
      }
    }
  } catch (_) {}
  return null;
}

Future<String?> defaultScanPrefix() async =>
    (await detectLanRange())?.activePrefix;

/// Reports only hosts accepting at least one tested TCP port; this is
/// not a complete inventory of devices behind firewalls or with no open ports.
Future<List<LanHost>> scanPrivate24(
  String prefix, {
  void Function(int completed, int total)? onProgress,
  bool Function()? cancelled,
  int parallelism = 24,
  int hostCount = 254,
  Duration timeout = const Duration(milliseconds: 450),
}) async {
  prefix = prefix.trim();
  if (!validPrivate24Prefix(prefix)) {
    throw const FormatException('Enter a private IPv4 /24 prefix, e.g. 192.168.1');
  }
  if (parallelism < 1 || parallelism > 32 || hostCount < 1 || hostCount > 254) {
    throw const FormatException('Invalid scan bounds.');
  }
  final results = <LanHost>[];
  var next = 1;
  var done = 0;
  Future<bool> listening(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> worker() async {
    while (next <= hostCount && !(cancelled?.call() ?? false)) {
      final last = next++;
      final host = '$prefix.$last';
      final checked = await Future.wait(
        lanScanPorts.map((port) => listening(host, port)),
      );
      final ports = <int>[
        for (var i = 0; i < lanScanPorts.length; i++)
          if (checked[i]) lanScanPorts[i],
      ];
      if (ports.isNotEmpty) {
        var name = host;
        try {
          final resolved = await InternetAddress(host)
              .reverse()
              .timeout(const Duration(milliseconds: 650));
          if (resolved.host != host) name = resolved.host;
        } on SocketException {
          // Reverse DNS isn't always configured on local networks.
        } on TimeoutException {
          // Keep the discovered IP without blocking the scan.
        }
        results.add(LanHost(ip: host, hostname: name, openPorts: ports));
      }
      done++;
      if (done % 8 == 0 || done == hostCount) onProgress?.call(done, hostCount);
    }
  }
  await Future.wait(List.generate(
    parallelism < hostCount ? parallelism : hostCount,
    (_) => worker(),
  ));
  return results..sort((a, b) {
    final left = a.ip.split('.').last;
    final right = b.ip.split('.').last;
    return int.parse(left).compareTo(int.parse(right));
  });
}
