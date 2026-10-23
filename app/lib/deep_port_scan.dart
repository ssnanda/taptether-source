import 'dart:async';
import 'dart:io';

import 'lan_scan.dart';

/// Advanced, user-triggered TCP diagnostics. Never used by passive discovery.
/// One host at a time, at most 48 simultaneous connections, no credential
/// exchange, banners, UDP flood, HTTP requests or service exploitation.
const int deepTcpPortCount = 65535;

List<String> parseDeepScanTargets(
    String input, DetectedLanRange network) {
  final unique = <String>{};
  for (final text in input.split(RegExp(r'[,;\s]+'))) {
    final ip = text.trim();
    if (ip.isEmpty) continue;
    if (!lanRangeContains(network, ip)) {
      throw FormatException('$ip is not on the current Wi-Fi subnet.');
    }
    unique.add(ip);
    if (unique.length > 32) {
      throw const FormatException(
        'Use full-network mode for more than 32 individual IP addresses.');
    }
  }
  if (unique.isEmpty) {
    throw const FormatException('Enter at least one local device IP.');
  }
  return unique.toList();
}

/// Enumerates all assignable addresses on a detected Wi-Fi CIDR.
/// The app allows full network scanning only for up to 4096 hosts.
List<String> deepScanNetworkHosts(DetectedLanRange network) {
  final parts = network.ip.split('.').map(int.parse).toList();
  final mask = network.subnetMask.split('.').map(int.parse).toList();
  if (parts.length != 4 || mask.length != 4) {
    throw const FormatException('Invalid Wi-Fi network.');
  }
  var address = 0, netmask = 0;
  for (var i = 0; i < 4; i++) {
    address = (address << 8) | parts[i];
    netmask = (netmask << 8) | mask[i];
  }
  final base = address & netmask;
  final broadcast = base | (~netmask & 0xffffffff);
  final count = broadcast - base - 1;
  if (count < 1 || count > 4096) {
    throw const FormatException(
        'Full-network deep scanning is limited to 4096 hosts.');
  }
  return List<String>.generate(count, (i) {
    final value = base + i + 1;
    return [24, 16, 8, 0].map((shift) =>
        ((value >> shift) & 255).toString()).join('.');
  });
}

typedef DeepProbe = Future<bool> Function(
    String host, int port, Duration timeout);

Future<bool> probeDeepTcp(String host, int port, Duration timeout) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  } on OSError {
    return false;
  }
}

class DeepHostResult {
  const DeepHostResult(this.ip, this.openPorts, this.checked);
  final String ip;
  final List<int> openPorts;
  final int checked;
}

/// Every port in the requested interval is attempted unless cancelled.
/// Errors/filtered packets are reported only as no TCP response, NOT offline.
/// Progress may be throttled by the UI; the scanner never changes saved devices.
Future<List<DeepHostResult>> scanDeepTcp({
  required List<String> hosts,
  required DetectedLanRange network,
  int firstPort = 1,
  int lastPort = 65535,
  int parallelism = 48,
  Duration timeout = const Duration(milliseconds: 300),
  bool Function()? cancelled,
  void Function(int checked, int total, String host)? onProgress,
  void Function(DeepHostResult result)? onHostCompleted,
  DeepProbe probe = probeDeepTcp,
}) async {
  if (firstPort < 1 || lastPort > 65535 || lastPort < firstPort ||
      parallelism < 1 || parallelism > 48) {
    throw const FormatException('Invalid TCP scan parameters.');
  }
  if (hosts.isEmpty || hosts.length > 4096 ||
      hosts.any((ip) => !lanRangeContains(network, ip))) {
    throw const FormatException('Deep scan hosts must be on current Wi-Fi.');
  }
  final total = hosts.length * (lastPort - firstPort + 1);
  var totalChecked = 0;
  final results = <DeepHostResult>[];
  for (final host in hosts) {
    if (cancelled?.call() ?? false) break;
    final openPorts = <int>[];
    var nextPort = firstPort;
    var hostChecked = 0;
    Future<void> worker() async {
      while (nextPort <= lastPort && !(cancelled?.call() ?? false)) {
        final port = nextPort++;
        final opened = await probe(host, port, timeout);
        if (opened) openPorts.add(port);
        hostChecked++;
        totalChecked++;
        if (totalChecked % 128 == 0 || totalChecked == total) {
          onProgress?.call(totalChecked, total, host);
        }
      }
    }
    await Future.wait(List.generate(
        parallelism.clamp(1, lastPort - firstPort + 1),
        (_) => worker()));
    openPorts.sort();
    final result = DeepHostResult(host, openPorts, hostChecked);
    results.add(result);
    onHostCompleted?.call(result);
    onProgress?.call(totalChecked, total, host);
  }
  return results;
}
