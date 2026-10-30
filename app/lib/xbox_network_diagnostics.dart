import 'lan_scan.dart';
import 'xbox_smartglass.dart';

/// Bounded, manual-only LAN diagnostics. Open TCP ports are reachability
/// hints, never authenticated Xbox identities. UDP silence is inconclusive.
class XboxNetworkReport {
  const XboxNetworkReport({
    required this.cidr,
    required this.consoleReplies,
    required this.tcpHosts,
    required this.udpStats,
    required this.checkedAddresses,
    required this.totalAddresses,
    required this.truncated,
    required this.targetPorts,
    this.targetIp,
  });

  final String cidr;
  final String? targetIp;
  final List<XboxConsole> consoleReplies;
  final List<LanHost> tcpHosts;
  final XboxDiscoveryStats udpStats;
  final int checkedAddresses;
  final int totalAddresses;
  final bool truncated;
  final Map<int, TcpProbeStatus> targetPorts;

  bool get targetDiscovered => targetIp != null &&
      consoleReplies.any((console) => console.host == targetIp);
  bool get targetTcpOpen =>
      targetPorts.values.any((status) => status == TcpProbeStatus.open);
}

/// Constrains full scans to four /24 slices (up to 1,024 local addresses).
/// For a /22 (such as 192.168.68.0/22), this covers the entire CIDR.
/// Larger ranges explicitly report truncation rather than claiming success.
String formatXboxNetworkDiagnostics(XboxNetworkReport report) {
  final rows = <String>[
    'TapTether Xbox LAN diagnostics',
    'Wi-Fi CIDR: ${report.cidr}',
    if (report.targetIp != null) 'Target IP: ${report.targetIp}',
    'Address probes: ${report.checkedAddresses}/${report.totalAddresses}',
    'Legacy Xbox UDP 5050 requests: ${report.udpStats.sent}',
    'Legacy Xbox replies: ${report.udpStats.replies}',
    'Compatible replies: ${report.udpStats.compatible}',
    'Other UDP replies: ${report.udpStats.malformed}',
    'TCP-visible hosts: ${report.tcpHosts.length}',
    if (report.truncated) 'NOTICE: Scan limited to first four /24 ranges',
    for (final entry in report.targetPorts.entries)
      'Target TCP ${entry.key}: ${tcpProbeLabel(entry.value)}',
    for (final host in report.tcpHosts)
      '${host.ip} TCP: ${host.openPorts.join(", ")}',
    'Note: TCP or UDP reachability is not authenticated Xbox identity.',
  ];
  return rows.join('\\n');
}

List<String> xboxDiagnosticPrefixes(DetectedLanRange range) =>
    range.scanPrefixes.take(4).toList();

int xboxDiagnosticHostCount(DetectedLanRange range) {
  var count = 0;
  for (final prefix in xboxDiagnosticPrefixes(range)) {
    final bounds = scanPrefixBounds(range, prefix);
    count += bounds.endHost - bounds.startHost + 1;
  }
  return count;
}

Future<XboxNetworkReport> runXboxNetworkDiagnostics({
  String? targetIp,
  bool fullNetwork = false,
  void Function(int completed, int total, String stage)? onProgress,
}) async {
  final range = await detectLanRange();
  if (range == null) {
    throw StateError('Connect to Wi-Fi to scan your local network.');
  }
  if (targetIp != null &&
      !lanRangeContains(range, targetIp)) {
    throw const FormatException(
        'That IP is not on the iPhone’s current Wi-Fi subnet.');
  }
  final stats = XboxDiscoveryStats();
  final discovery = discoverXboxConsoles(
    targetIp: targetIp, fullNetwork: fullNetwork,
    diagnostics: stats, duration: const Duration(seconds: 2),
  );

  final ports = <int, TcpProbeStatus>{};
  if (targetIp != null) {
    const probePorts = [5050, 3074, 9002, 80, 443];
    final results = await Future.wait([
      for (final port in probePorts)
        probeTcpPort(targetIp, port,
            timeout: const Duration(milliseconds: 700)),
    ]);
    for (var i = 0; i < probePorts.length; i++) {
      ports[probePorts[i]] = results[i];
    }
    onProgress?.call(1, 1, 'Checked TCP services on $targetIp');
  }

  final hosts = <String, LanHost>{};
  var checked = 0;
  var total = targetIp == null ? 0 : 1;
  final prefixes = fullNetwork ? xboxDiagnosticPrefixes(range) : <String>[];
  if (fullNetwork) {
    checked = 0;
    total = xboxDiagnosticHostCount(range);
    for (final prefix in prefixes) {
      final bounds = scanPrefixBounds(range, prefix);
      final blockLength = bounds.endHost - bounds.startHost + 1;
      final blockStart = checked;
      final blockHosts = await scanPrivate24(
        prefix,
        startHost: bounds.startHost,
        endHost: bounds.endHost,
        onProgress: (completed, blockTotal) {
          if (completed == blockTotal || completed % 16 == 0) {
            onProgress?.call(blockStart + completed, total,
                'Probing $prefix.0/24');
          }
        },
      );
      for (final item in blockHosts) {
        hosts[item.ip] = item;
      }
      checked += blockLength;
    }
  }
  final found = await discovery;
  return XboxNetworkReport(
    cidr: range.cidr,
    targetIp: targetIp,
    consoleReplies: found,
    tcpHosts: hosts.values.toList()
      ..sort((a, b) => a.ip.compareTo(b.ip)),
    udpStats: stats,
    checkedAddresses: checked,
    totalAddresses: total,
    truncated: fullNetwork &&
        xboxDiagnosticHostCount(range) < range.scanPrefixes.fold<int>(
            0, (sum, prefix) {
          final bounds = scanPrefixBounds(range, prefix);
          return sum + bounds.endHost - bounds.startHost + 1;
        }),
    targetPorts: ports,
  );
}
