import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'discovery.dart';
import 'lan_scan.dart';
import 'lg_webos_client.dart';
import 'samsung_tv_client.dart';
import 'device_location_log.dart';

/// Opt-in LAN diagnostics for each saved device type.
/// No pairing or TLS credentials are copied into this screen's report.
class DeviceDiagnosticsScreen extends StatefulWidget {
  const DeviceDiagnosticsScreen({
    super.key,
    required this.name,
    required this.host,
    required this.kind,
    this.location = 'other',
    this.paired = false,
    this.hasTlsPin = false,
    this.reportedOnline,
    this.model = '',
    this.about = const {},
    this.lastError,
    this.verifyAuthenticated,
    this.locationLogKey = '',
    this.onLocate,
    this.currentHost,
  });

  final String name;
  final String host;
  /// darwin, linux, windows, lg, samsung or unknown.
  final String kind;
  final String location;
  final bool paired;
  final bool hasTlsPin;
  final bool? reportedOnline;
  final String model;
  final Map<String, String> about;
  final String? lastError;
  /// Read-only authenticated check supplied by a trusted caller.
  final Future<Map<String, String>> Function()? verifyAuthenticated;
  /// Stable paired-device identity, never the floating address.
  final String locationLogKey;
  /// Uses existing authenticated discovery; never enrolls new devices.
  final Future<void> Function()? onLocate;
  final String Function()? currentHost;

  @override
  State<DeviceDiagnosticsScreen> createState() =>
      _DeviceDiagnosticsScreenState();
}

/// Sanitizes unexpected platform errors and vendor response text.
String redactDiagnosticText(String value) {
  var safe = value.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), ' ');
  safe = safe.replaceAll(RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer [REDACTED]');
  safe = safe.replaceAllMapped(RegExp(
      r'(token|client[_-]?key|password|secret|session|authorization|fingerprint|tls[_-]?pin)\s*[:=]\s*[^\s,;&}]+',
      caseSensitive: false),
      (match) => '${match.group(1)}=[REDACTED]');
  safe = safe.replaceAll(RegExp(r'\b[a-f0-9]{64}\b', caseSensitive: false),
      '[REDACTED-HASH]');
  return safe.length > 1000 ? '${safe.substring(0, 1000)}…' : safe;
}

String diagnosticReport({
  required String name,
  required String kind,
  required String host,
  required DateTime timestamp,
  required Map<String, String> details,
}) {
  final buffer = StringBuffer()
    ..writeln('TapTether device diagnostics')
    ..writeln('Generated: ${timestamp.toUtc().toIso8601String()} (UTC)')
    ..writeln('Device: ${redactDiagnosticText(name)}')
    ..writeln('Type: ${redactDiagnosticText(kind)}')
    ..writeln('Saved LAN address: ${redactDiagnosticText(host)}')
    ..writeln('NOTE: Contains local network details; review before sharing.')
    ..writeln('No pairing tokens, client keys, passwords or TLS fingerprints included.')
    ..writeln('');
  for (final entry in details.entries) {
    buffer.writeln('${redactDiagnosticText(entry.key)}: '
        '${redactDiagnosticText(entry.value)}');
  }
  return buffer.toString();
}

class _DeviceDiagnosticsScreenState extends State<DeviceDiagnosticsScreen> {
  final Map<String, String> _details = {};
  bool _running = false;
  bool _locating = false;
  DateTime? _lastRun;
  String? _report;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() { _running = true; _report = null; _details.clear(); });
    final details = <String, String>{};
    void add(String label, String value) =>
        details[label] = redactDiagnosticText(value);
    final currentHost = widget.currentHost?.call() ?? widget.host;
    add('Connection category', widget.kind);
    add('Saved pairing', widget.paired ? 'Yes' : 'No');
    add('Certificate pin stored', widget.hasTlsPin ? 'Yes (value omitted)' : 'No');
    add('Last dashboard reachability', widget.reportedOnline == null
        ? 'Not checked' : widget.reportedOnline! ? 'Online' : 'Offline');
    add('Location label', widget.location);
    if (widget.locationLogKey.isNotEmpty) {
      try {
        final events = await DeviceLocationLog.instance
            .read(widget.locationLogKey);
        if (events.isEmpty) {
          add('Location history', 'No location attempts recorded');
        } else {
          for (var i = 0; i < events.length && i < 16; i++) {
            add('Locate event ${i + 1}', events[i]);
          }
        }
      } catch (_) {
        add('Location history', 'Unavailable on this phone');
      }
    }
    if (widget.model.isNotEmpty) add('Model', widget.model);
    for (final entry in widget.about.entries.take(32)) {
      if (RegExp(r'token|key|secret|password|pin|fingerprint|session',
          caseSensitive: false).hasMatch(entry.key)) {
        continue;
      }
      add('TV ${entry.key}', entry.value);
    }
    if (widget.lastError?.isNotEmpty == true) {
      add('Last operation error', widget.lastError!);
    }
    try {
      final info = await PackageInfo.fromPlatform();
      add('TapTether app', '${info.version}+${info.buildNumber}');
    } catch (_) {
      add('TapTether app', 'Version unavailable');
    }
    add('Phone platform', Platform.operatingSystem);
    var onCurrentLan = true;
    try {
      final lan = await detectLanRange();
      if (lan == null) {
        add('Current Wi-Fi LAN', 'Unavailable (permissions, cellular, VPN or Wi-Fi off)');
        add('LAN subnet match', 'Unknown');
      } else {
        add('Current Wi-Fi LAN', '${lan.ip} / ${lan.cidr}');
        add('Subnet mask', lan.subnetMask);
        add('Wi-Fi SSID', lan.ssid?.isNotEmpty == true ? lan.ssid! : 'Not available');
        onCurrentLan = lanRangeContains(lan, currentHost);
        add('LAN subnet match', onCurrentLan ? 'Yes' : 'No');
      }
    } catch (error) {
      add('Current Wi-Fi LAN', 'Detection failed: $error');
    }

    if (!isPrivateIPv4(currentHost)) {
      add('Device address validation', 'Not a private IPv4; active tests skipped');
    } else if (!onCurrentLan) {
      add('Active checks', 'Skipped: saved IP is outside current Wi-Fi subnet. Re-discover and verify device identity first.');
    } else {
      const portSets = <String, List<int>>{
        'darwin': [48321, 22], 'linux': [48321, 22],
        'windows': [48321, 3389], 'lg': [3001, 3000],
        'samsung': [8002, 8001],
        'unknown': [48321, 3001, 3000, 8002, 8001, 22, 80, 443],
      };
      final ports = portSets[widget.kind] ?? portSets['unknown']!;
      final results = await Future.wait(ports.map((port) async {
        final watch = Stopwatch()..start();
        try {
          final status = await probeTcpPort(currentHost, port,
              timeout: const Duration(milliseconds: 1100));
          return MapEntry(port, '${status.name} (${watch.elapsedMilliseconds} ms)');
        } catch (error) {
          return MapEntry(port, 'error (${redactDiagnosticText('$error')})');
        }
      }));
      for (final result in results) {
        add('TCP ${result.key}', result.value);
      }
      if (widget.kind == 'lg') {
        try {
          final hello = await readLgWebOsHello(currentHost,
              connectTimeout: const Duration(milliseconds: 650),
              replyTimeout: const Duration(seconds: 2));
          add('LG webOS hello', hello == null
              ? 'No valid webOS response' : 'LG webOS protocol detected (not authentication)');
        } catch (error) {
          add('LG webOS hello', 'Failed: $error');
        }
        add('LG pairing validation', widget.hasTlsPin
            ? 'Saved TLS pin exists; use authenticated pin check below'
            : 'Not available without a saved certificate pin');
      } else if (widget.kind == 'samsung') {
        try {
          final info = await probeSamsungTv(currentHost,
              timeout: const Duration(seconds: 2));
          add('Samsung device info', info == null
              ? 'No valid Samsung /api/v2 response'
              : 'Samsung protocol detected (not pairing authentication)');
          if (info != null && info.model.isNotEmpty) {
            add('Reported TV model', info.model);
          }
        } catch (error) {
          add('Samsung device info', 'Failed: $error');
        }
        add('Samsung pairing validation',
            'Read-only checks cannot prove token authorization; connect using saved remote');
      }
      if (widget.verifyAuthenticated != null) {
        try {
          final authenticated = await widget.verifyAuthenticated!()
              .timeout(const Duration(seconds: 9));
          for (final entry in authenticated.entries) {
            add('Authenticated ${entry.key}', entry.value);
          }
        } catch (error) {
          add('Authenticated agent check', 'Failed: $error');
        }
      } else if (const ['darwin', 'linux', 'windows'].contains(widget.kind)) {
        add('Authenticated agent check',
            'Unavailable (pairing verification callback not supplied)');
      }
    }
    if (!mounted) return;
    final now = DateTime.now();
    setState(() {
      _lastRun = now;
      _details.addAll(details);
      _report = diagnosticReport(name: widget.name, kind: widget.kind,
          host: currentHost, timestamp: now, details: details);
      _running = false;
    });
  }

  Future<void> _locateNow() async {
    if (_running || _locating || widget.onLocate == null) return;
    setState(() => _locating = true);
    try {
      await widget.onLocate!();
    } catch (_) {
      // Actual recovery details are recorded by the controller.
    } finally {
      if (mounted) setState(() => _locating = false);
    }
    if (mounted) await _run();
  }

  Future<void> _copy() async {
    final report = _report;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Diagnostics copied. Paste into your support chat.'),
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Device Diagnostics')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Text(widget.name, style: Theme.of(context).textTheme.titleLarge),
      Text('${widget.kind} · ${widget.currentHost?.call() ?? widget.host}'),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: FilledButton.icon(
          key: const ValueKey('run-device-diagnostics'),
          onPressed: _running ? null : _run,
          icon: const Icon(Icons.network_check), label: Text(
              _running ? 'Running checks…' : 'Run again'),
        )),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton.icon(
          key: const ValueKey('copy-device-diagnostics'),
          onPressed: _report == null ? null : _copy,
          icon: const Icon(Icons.copy_all_outlined),
          label: const Text('Copy report'),
        )),
      ]),
      if (widget.onLocate != null) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('locate-from-diagnostics'),
          onPressed: _running || _locating ? null : _locateNow,
          icon: const Icon(Icons.travel_explore),
          label: Text(_locating ? 'Locating…' : 'Locate device now'),
        ),
      ],
      if (_running || _locating)
        const Padding(padding: EdgeInsets.symmetric(vertical: 12),
          child: LinearProgressIndicator()),
      const SizedBox(height: 10),
      const Text('Checks stay local. Location history includes verified '
          'IP changes and discovery results; copied reports may contain '
          'your Wi-Fi name and local IP addresses.'),
      if (_lastRun != null) ...[
        const SizedBox(height: 12),
        Text('Last run: ${_lastRun!.toLocal()}'),
        const SizedBox(height: 6),
        Card(child: Padding(padding: const EdgeInsets.all(12),
          child: SelectableText(_report ?? '',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        )),
      ],
    ]),
  );
}
