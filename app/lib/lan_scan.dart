import 'dart:async';
import 'dart:io';

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

Future<String?> defaultScanPrefix() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final prefix = prefixFromIp(address.address);
        if (prefix != null) return prefix;
      }
    }
  } on SocketException {
    // User may enter a subnet manually.
  }
  return null;
}

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
