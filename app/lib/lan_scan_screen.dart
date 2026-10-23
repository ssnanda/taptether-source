import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lan_scan.dart';
import 'deep_port_scan.dart';
import 'computer_store.dart';
import 'scan_report.dart';
import 'lg_webos_client.dart';
import 'samsung_tv_client.dart';
import 'lg_appliance_discovery.dart';
import 'lan_host_details_screen.dart';

/// Injecting a scanner permits deterministic tests of authenticated
/// scan-to-paired-device reconciliation without touching real network hosts.
typedef LanRangeScanner = Future<List<LanHost>> Function(
  String prefix, {
  void Function(int completed, int total)? onProgress,
  void Function(LanHost candidate)? onAgentFound,
  void Function(String ip, List<int> respondingPorts)? onProbe,
  bool Function()? cancelled,
  required int startHost,
  int? endHost,
});

/// Manual on-device /24 scan. No internet API, cloud account or analytics.
class LanScanScreen extends StatefulWidget {
  const LanScanScreen({
    super.key, this.initialIp, this.knownComputers = const [],
    this.macResolver,
    this.verifyPairedAgent,
    this.scanRange,
    this.initialNetwork,
  });
  final String? initialIp;
  final List<SavedComputer> knownComputers;
  final Future<Map<String, String>> Function()? macResolver;
  /// Triggered only on explicit user scan. The caller authenticates this IP
  /// with a saved TLS certificate pin AND paired-phone credentials before
  /// returning the matching computer name or changing a saved record.
  final Future<String?> Function(String ip)? verifyPairedAgent;
  final LanRangeScanner? scanRange;
  final DetectedLanRange? initialNetwork;

  @override
  State<LanScanScreen> createState() => _LanScanScreenState();
}

class _LanScanScreenState extends State<LanScanScreen> {
  final _prefix = TextEditingController();
  final _specificIp = TextEditingController();
  final _targetIps = TextEditingController();
  DetectedLanRange? _network;
  bool _checkingSpecificIp = false;
  Map<int, TcpProbeStatus> _specificPortResults = {};
  String? _lgProtocolResult;
  String? _notRespondingIp;
  bool _editedPrefix = false;
  List<LanHost> _hosts = [];
  Map<String, String> _cachedMacs = {};
  final Map<String, String> _verifiedAgents = {};
  final Set<String> _startedVerification = {};
  final List<Future<void>> _pendingVerifications = [];
  final ScanReport _report = ScanReport();
  bool _busy = false;
  bool _cancel = false;
  int _completed = 0;
  int _total = 254;
  bool _scanWholeNetwork = true;
  bool _scanTargetedIps = false;
  bool _scanLg = false;
  bool _scanSamsung = false;
  bool _vendorBusy = false;
  int _vendorChecked = 0;
  int _vendorTotal = 0;
  final Map<String, String> _vendorModels = {};
  bool _deepTcpPorts = false;
  bool _deepOnlyResponsive = true;
  int _deepCompleted = 0;
  int _deepTotal = 0;
  String? _deepCurrentIp;
  DateTime _lastDeepProgress = DateTime.fromMillisecondsSinceEpoch(0);
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDefault());
  }

  Future<void> _loadDefault() async {
    final range = widget.initialNetwork ?? await detectLanRange();
    if (!mounted) return;
    setState(() {
      _network = range;
      if (!_editedPrefix) {
        _prefix.text = range?.activePrefix ??
            (prefixFromIp(widget.initialIp ?? '') ?? '');
      }
      if (_specificIp.text.isEmpty &&
          widget.initialIp != null && widget.initialIp!.isNotEmpty) {
        _specificIp.text = widget.initialIp!;
        _targetIps.text = widget.initialIp!;
      }
    });
  }

  @override
  void dispose() {
    _cancel = true;
    _prefix.dispose();
    _specificIp.dispose();
    _targetIps.dispose();
    super.dispose();
  }

  void _verifyCandidate(LanHost candidate) {
    if (_cancel || !mounted || widget.verifyPairedAgent == null) return;
    if (!candidate.openPorts.contains(48321) && !candidate.agentAnnounced) {
      return;
    }
    if (!_startedVerification.add(candidate.ip)) return;
    final task = _authenticateCandidate(candidate.ip);
    _pendingVerifications.add(task);
  }

  Future<void> _authenticateCandidate(String ip) async {
    try {
      final name = await widget.verifyPairedAgent!(ip);
      if (mounted && !_cancel) {
        _report.add(name == null
            ? '$ip: no matching authenticated saved pairing'
            : '$ip: existing paired computer verified');
        if (name != null) setState(() => _verifiedAgents[ip] = name);
      }
    } catch (_) {
      // A foreign service or an unpaired agent must never interrupt IP Scan.
      _report.add('$ip: authentication check did not complete');
    }
  }

  void _showAgentCandidate(LanHost host) {
    _verifyCandidate(host);
    if (!mounted || _cancel || _hosts.any((item) => item.ip == host.ip)) {
      return;
    }
    // A listening TapTether port can appear while other IPs are still being
    // scanned. Show the candidate immediately while verification runs.
    setState(() {
      _hosts = [..._hosts, host]..sort((a, b) {
        final left = a.ip.split('.').map(int.parse).toList();
        final right = b.ip.split('.').map(int.parse).toList();
        for (var i = 0; i < 4; i++) {
          final diff = left[i].compareTo(right[i]);
          if (diff != 0) return diff;
        }
        return 0;
      });
    });
  }


  Future<bool> _confirmDeepNetwork() async {
    if (!_deepTcpPorts || _scanTargetedIps) return true;
    final full = _scanWholeNetwork && _network != null;
    return await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Run a deep TCP scan?'),
        content: Text(full
            ? _deepOnlyResponsive
                ? 'TapTether first scans this Wi-Fi network, then attempts '
                  'TCP ports 1–65535 on responding hosts only. Devices '
                  'with all quick-scan ports closed can be missed.'
                : 'This tests all 65,535 TCP ports on EVERY address '
                  'in the Wi-Fi subnet, including silent hosts. '
                  'Millions of connections may take hours or longer '
                  'and consume considerable battery.'
            : _deepOnlyResponsive
                ? 'TapTether first checks this /24, then tests all '
                  '65,535 TCP ports on responding hosts. Silent '
                  'devices can be missed.'
                : 'This tests all 65,535 TCP ports for every address '
                  'in the selected /24, including silent hosts. '
                  'This can take hours or longer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Start deep scan')),
        ],
      ),
    ) ?? false;
  }

  Future<void> _runDeepTcp(List<String> targets) async {
    if (_cancel || targets.isEmpty) {
      if (targets.isEmpty) {
        _report.add('No quick-scan responders. Uncheck '
            '"Only deep-scan responsive hosts" or choose specific IPs.');
      }
      return;
    }
    final network = _network;
    if (network == null) return;
    final unique = targets.toSet().toList();
    _deepTotal = unique.length * deepTcpPortCount;
    _deepCompleted = 0;
    _report.add('Deep scan: ${unique.length} local host(s); '
      '65,535 TCP ports per host; up to 48 concurrent attempts '
      'per host, 300ms timeout. TCP only; no response != offline.');
    await scanDeepTcp(
      hosts: unique,
      network: network,
      cancelled: () => _cancel || !mounted,
      onProgress: (done, total, ip) {
        final now = DateTime.now();
        if (mounted && (now.difference(_lastDeepProgress) >
            const Duration(milliseconds: 220) || done == total)) {
          _lastDeepProgress = now;
          setState(() {
            _deepCompleted = done;
            _deepTotal = total;
            _deepCurrentIp = ip;
          });
        }
      },
      onHostCompleted: (result) {
        if (!mounted) return;
        _report.add('${result.ip}: probed ${result.checked} TCP ports; '
            'open: ${result.openPorts.isEmpty
                ? "none identified" : result.openPorts.join(", ")}'
            '${result.openPorts.isEmpty
                ? " (not proof of offline)" : ""}');
        final existing = _hosts.where((item) =>
            item.ip == result.ip).toList();
        final mergedPorts = <int>{
          if (existing.isNotEmpty) ...existing.first.openPorts,
          ...result.openPorts,
        }.toList()..sort();
        // Silence/filtered ports are not proof of an offline host.
        // Avoid creating hundreds of meaningless cards for CIDR scans.
        if (mergedPorts.isEmpty && existing.isEmpty) return;
        if (existing.isEmpty && _hosts.length >= 250) return;
        setState(() {
          _hosts = [
            for (final item in _hosts)
              if (item.ip != result.ip) item,
            LanHost(
              ip: result.ip,
              hostname: existing.isEmpty
                  ? result.ip : existing.first.hostname,
              openPorts: mergedPorts,
              macAddress: existing.isEmpty
                  ? null : existing.first.macAddress,
              platform: existing.isEmpty
                  ? null : existing.first.platform,
              agentAnnounced: existing.isNotEmpty &&
                  existing.first.agentAnnounced,
            ),
          ];
        });
      },
    );
    _report.add(_cancel
        ? 'Deep TCP scan stopped early at $_deepCompleted/$_deepTotal probes.'
        : 'Deep TCP scan complete. Open ports are not proof of device identity.');
  }

  void _addVendorCandidate(String ip, String name, List<int> ports,
      {String? model}) {
    if (!mounted) return;
    final existing = _hosts.where((item) => item.ip == ip).toList();
    final previous = existing.isEmpty ? null : existing.first;
    final mergedPorts = <int>{
      ...?previous?.openPorts,
      ...ports,
    }.toList()..sort();
    setState(() {
      if (model != null && model.isNotEmpty) _vendorModels[ip] = model;
      _hosts = [
        for (final item in _hosts)
          if (item.ip != ip) item,
        LanHost(
          ip: ip,
          hostname: previous == null || previous.hostname == ip
              ? name : previous.hostname,
          openPorts: mergedPorts,
          macAddress: previous?.macAddress,
          platform: previous?.platform,
          agentAnnounced: previous?.agentAnnounced ?? false,
        ),
      ]..sort((a, b) {
        final aa = a.ip.split('.').map(int.parse).toList();
        final bb = b.ip.split('.').map(int.parse).toList();
        for (var i = 0; i < 4; i++) {
          final diff = aa[i].compareTo(bb[i]);
          if (diff != 0) return diff;
        }
        return 0;
      });
    });
  }

  Future<void> _scanVendorHints(List<String> ips) async {
    if (_cancel || !mounted || (!_scanLg && !_scanSamsung)) return;
    final network = _network;
    if (network == null) return;
    final targets = ips.toSet().where((ip) =>
        lanRangeContains(network, ip)).take(4096).toList();
    setState(() {
      _vendorBusy = true;
      _vendorChecked = 0;
      _vendorTotal = targets.length;
    });
    _report.add('Vendor read-only checks: '
        '${_scanLg ? "LG" : ""} ${_scanSamsung ? "Samsung" : ""} '
        '· ${targets.length} local host(s), no pairing or control.');
    try {
      if (_scanLg) {
        try {
          final clues = await LgApplianceLanDiscovery().scan(network);
          _report.add('LG multicast advertisements: ${clues.length}');
          for (final item in clues) {
            _report.add('${item.ip}: possible LG ${item.name}; '
                'model: ${item.model.isEmpty ? "not advertised" : item.model}');
            _addVendorCandidate(item.ip, item.name, const [],
                model: item.model);
          }
        } catch (_) {
          _report.add('LG multicast discovery unavailable.');
        }
      }
      var index = 0;
      Future<void> worker() async {
        while (index < targets.length && !_cancel && mounted) {
          final ip = targets[index++];
          if (_scanLg) {
            final results = await Future.wait([
              probeTcpPort(ip, 3000,
                  timeout: const Duration(milliseconds: 330)),
              probeTcpPort(ip, 3001,
                  timeout: const Duration(milliseconds: 330)),
            ]);
            final ports = <int>[
              if (results[0] == TcpProbeStatus.open) 3000,
              if (results[1] == TcpProbeStatus.open) 3001,
            ];
            if (ports.isNotEmpty) {
              final hello = await readLgWebOsHello(ip,
                connectTimeout: const Duration(milliseconds: 600),
                replyTimeout: const Duration(seconds: 2));
              _report.add('$ip: LG webOS ${hello == null
                  ? "ports open, protocol unverified"
                  : "read-only hello confirmed"}');
              if (hello != null) {
                _addVendorCandidate(ip, 'LG webOS TV', ports);
              }
            }
          }
          if (_scanSamsung) {
            final samsung = await probeSamsungTv(ip,
                timeout: const Duration(milliseconds: 700));
            if (samsung != null) {
              _report.add('$ip: Samsung Tizen/Smart View confirmed · '
                  'model ${samsung.model.isEmpty
                      ? "not disclosed" : samsung.model}');
              _addVendorCandidate(ip, 'Samsung TV', const [8001],
                  model: samsung.model);
            }
          }
          _vendorChecked++;
          if (_vendorChecked % 12 == 0 ||
              _vendorChecked == _vendorTotal) {
            if (mounted) setState(() {});
          }
        }
      }
      await Future.wait(List.generate(
          targets.length < 12 ? targets.length : 12, (_) => worker()));
      _report.add('Vendor checks finished: $_vendorChecked/'
          '$_vendorTotal hosts. Hints are not authenticated identities.');
    } finally {
      if (mounted) setState(() => _vendorBusy = false);
    }
  }

  Future<void> _startTargetedScan() async {
    final network = _network;
    if (network == null) {
      setState(() => _error = 'Join Wi-Fi to scan specific IPs.');
      return;
    }
    late final List<String> targets;
    try {
      targets = parseDeepScanTargets(_targetIps.text, network);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    _report.clear();
    _report.add('Targeted LAN scan: ${targets.join(", ")}');
    _report.add('Mode: ${_deepTcpPorts ? "deep TCP 1–65535"
        : "quick TCP ports"}');
    setState(() {
      _error = null;
      _cancel = false;
      _busy = true;
      _completed = 0;
      _total = targets.length;
      _deepCompleted = 0;
      _deepTotal = 0;
      _hosts = [];
      _vendorModels.clear();
      _verifiedAgents.clear();
      _startedVerification.clear();
      _pendingVerifications.clear();
    });
    try {
      if (_deepTcpPorts) {
        await _runDeepTcp(targets);
      } else {
        for (final ip in targets) {
          if (_cancel) break;
          final host = await checkPrivateLanIp(ip);
          if (!mounted) break;
          _report.add(host == null
              ? '$ip: no quick TCP response (not proof of offline)'
              : '$ip: TCP open ${host.openPorts.join(", ")}');
          final candidate = host ?? LanHost(
              ip: ip, hostname: ip, openPorts: const []);
          if (host != null) _verifyCandidate(host);
          setState(() {
            _hosts = [..._hosts, candidate];
            _completed++;
          });
        }
        if (!_cancel) await Future.wait(_pendingVerifications);
      }
      if (!_cancel && mounted) await _scanVendorHints(targets);
    } catch (_) {
      if (mounted) setState(() => _error =
          'Scan failed. Confirm the IPs are on your current Wi-Fi.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  Future<void> _startScan() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    if (_scanTargetedIps) {
      await _startTargetedScan();
      return;
    }
    if (!await _confirmDeepNetwork() || !mounted) return;
    final prefix = _prefix.text.trim();
    if (!validPrivate24Prefix(prefix)) {
      setState(() => _error = 'Enter a private IPv4 /24 prefix (e.g. 192.168.1).');
      return;
    }
    // Full-network mode uses the detected CIDR, including the .0/.255
    // addresses that are usable inside a /23 or /22. A custom prefix is
    // always a single /24; selecting one disables full-network mode.
    final wholeNetwork = _scanWholeNetwork && _network != null &&
        _network!.scanPrefixes.length <= 8;
    final targets = wholeNetwork ? _network!.scanPrefixes : [prefix];
    final bounds = <({int startHost, int endHost})>[
      for (final target in targets)
        wholeNetwork
            ? scanPrefixBounds(_network!, target)
            : (startHost: 1, endHost: 254),
    ];
    final total = bounds.fold<int>(0,
        (count, b) => count + b.endHost - b.startHost + 1);
    _report.clear();
    _report.add('Scan IPs started · Wi-Fi: ${_network?.ip ?? "unknown"} · '
        'Detected CIDR: ${_network?.cidr ?? "unknown"}');
    _report.add('Mode: ${wholeNetwork ? "entire Wi-Fi CIDR" : "single /24"} · '
        'TCP ports: ${lanScanPorts.join(", ")} · Timeout per probe: 450ms');
    for (var i = 0; i < targets.length; i++) {
      _report.add('Planned range: ${targets[i]}.${bounds[i].startHost} - '
          '${targets[i]}.${bounds[i].endHost}');
    }
    setState(() {
      _error = null;
      _hosts = [];
      _cachedMacs = {};
      _vendorModels.clear();
      _verifiedAgents.clear();
      _startedVerification.clear();
      _pendingVerifications.clear();
      _completed = 0;
      _total = total;
      _deepCompleted = 0;
      _deepTotal = 0;
      _deepCurrentIp = null;
      _cancel = false;
      _busy = true;
    });
    try {
      final found = <String, LanHost>{};
      var scannedBefore = 0;
      for (var index = 0; index < targets.length && !_cancel; index++) {
        final target = targets[index];
        final bound = bounds[index];
        _report.add('Scanning $target.0/24 '
            '(host suffixes ${bound.startHost}-${bound.endHost})');
        var closedOrFiltered = 0;
        final group = await (widget.scanRange ?? scanPrivate24)(target,
          startHost: bound.startHost,
          endHost: bound.endHost,
          cancelled: () => _cancel,
          onAgentFound: _showAgentCandidate,
          onProbe: (ip, ports) {
            if (ports.isEmpty) {
              closedOrFiltered++;
            } else {
              _report.add('$ip: TCP open ${ports.join(", ")}');
            }
          },
          onProgress: (done, _) {
            if (mounted) {
              setState(() => _completed = scannedBefore + done);
            }
          },
        );
        _report.add('Range $target.0/24 finished: '
            '${group.length} responsive/announced device(s) · '
            '$closedOrFiltered without an open tested TCP port '
            '(not proof of offline)');
        scannedBefore += bound.endHost - bound.startHost + 1;
        for (final computer in group) {
          found[computer.ip] = computer;
          _verifyCandidate(computer);
        }
        if (mounted) {
          setState(() {
            _hosts = found.values.toList()..sort((a, b) {
              final aa = a.ip.split('.').map(int.parse).toList();
              final bb = b.ip.split('.').map(int.parse).toList();
              for (var i = 0; i < 4; i++) {
                final diff = aa[i].compareTo(bb[i]);
                if (diff != 0) return diff;
              }
              return 0;
            });
          });
        }
      }
      // Do not declare the scan finished while identity checks are in
      // flight. Results are saved as soon as each individual match succeeds.
      if (!_cancel) {
        await Future.wait(_pendingVerifications);
      }
      _report.add(_cancel
          ? 'Scan stopped early: $_completed of $_total addresses checked'
          : 'IP scan completed: $_completed of $_total addresses checked · '
              '${found.length} discovered device(s) · '
              '${_verifiedAgents.length} paired computer(s) authenticated');
      if (!_cancel && mounted && (_scanLg || _scanSamsung)) {
        // Vendor checks are explicitly requested and may find hosts with
        // every quick-scan port closed, including LG appliances and TVs.
        final vendorTargets = [
          for (var i = 0; i < targets.length; i++)
            for (var suffix = bounds[i].startHost;
                suffix <= bounds[i].endHost; suffix++)
              '${targets[i]}.$suffix',
        ];
        await _scanVendorHints(vendorTargets);
      }
      if (_deepTcpPorts && !_cancel && mounted) {
        final deepTargets = _deepOnlyResponsive
            ? found.keys.toList()
            : wholeNetwork
                ? deepScanNetworkHosts(_network!)
                : [
                    for (var i = bounds.first.startHost;
                        i <= bounds.first.endHost; i++)
                      '$prefix.$i',
                  ];
        await _runDeepTcp(deepTargets);
      }
      // A paired, authenticated desktop can read its own ARP cache;
      // mobile iOS cannot directly inspect other devices' MAC addresses.
      if (!_cancel && widget.macResolver != null) {
        final neighbors = await widget.macResolver!();
        if (mounted) setState(() => _cachedMacs = neighbors);
      }
    } catch (_) {
      _report.add('Scan error: scan did not finish (details withheld)');
      if (mounted) {
        setState(() => _error =
            'The scan could not finish. Check Wi-Fi or local-network permission.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkSpecificIp() async {
    if (_checkingSpecificIp || _busy) return;
    final ip = _specificIp.text.trim();
    if (!validPrivate24Prefix(prefixFromIp(ip) ?? '')) {
      setState(() => _error = 'Enter a private IPv4 address, e.g. 192.168.1.77');
      return;
    }
    _report.add('Manual IP check: $ip · TCP ports ${lanScanPorts.join(", ")}');
    setState(() {
      _checkingSpecificIp = true;
      _notRespondingIp = null;
      _specificPortResults = {};
      _lgProtocolResult = null;
      _error = null;
    });
    try {
      final diagnostic = await Future.wait([3000, 3001].map(
        (port) => probeTcpPort(ip, port),
      ));
      final results = <int, TcpProbeStatus>{
        3000: diagnostic[0], 3001: diagnostic[1],
      };
      final hasLgPort = diagnostic.contains(TcpProbeStatus.open);
      final lgHello = hasLgPort ? await readLgWebOsHello(ip,
          connectTimeout: const Duration(milliseconds: 650),
          replyTimeout: const Duration(seconds: 2)) : null;
      final protocol = !hasLgPort
          ? 'LG control service not accepting connections on 3000/3001.'
          : lgHello == null
              ? 'LG protocol not confirmed (open port alone is not proof).'
              : 'LG webOS protocol confirmed.';
      _report.add('$ip: LG 3000 ${tcpProbeLabel(results[3000]!)} · '
          '3001 ${tcpProbeLabel(results[3001]!)} · $protocol');
      final found = await checkPrivateLanIp(ip);
      if (!mounted) return;
      _report.add(found == null
          ? '$ip: no tested service responded'
          : '$ip: TCP open ${found.openPorts.join(", ")}'
              '${found.agentAnnounced ? " · agent UDP reply" : ""}');
      _verifyCandidate(found ??
          LanHost(ip: ip, hostname: ip, openPorts: const []));
      setState(() {
        _specificPortResults = results;
        _lgProtocolResult = protocol;
        if (found == null) {
          _notRespondingIp = ip;
        }
        final candidate = found ?? LanHost(
            ip: ip, hostname: ip, openPorts: const []);
        _hosts = [
          for (final item in _hosts)
            if (item.ip != ip) item,
          candidate,
        ]..sort((a, b) {
            final left = a.ip.split('.').map(int.parse).toList();
            final right = b.ip.split('.').map(int.parse).toList();
            for (var i = 0; i < 4; i++) {
              final diff = left[i].compareTo(right[i]);
              if (diff != 0) return diff;
            }
            return 0;
          });
      });
    } catch (_) {
      _report.add('$ip: manual check failed');
      if (mounted) {
        setState(() => _error = 'Unable to check that LAN IP. '
            'Verify Wi-Fi and local-network permissions.');
      }
    } finally {
      if (mounted) setState(() => _checkingSpecificIp = false);
    }
  }

  /// Level-one report includes the visible device inventory, not only the
  /// low-level scan log. Copied data never leaves the phone automatically.
  String _networkDiagnostics() {
    final result = StringBuffer()
      ..writeln('TapTether network scan · ${_network?.cidr ?? "unknown"}')
      ..writeln('Found ${_hosts.length} device(s)');
    for (final host in _hosts) {
      final verified = _verifiedAgents[host.ip];
      final name = verified ?? host.displayName;
      result.writeln('${host.ip} · $name · '
          'TCP ${host.openPorts.isEmpty
              ? "no tested response" : host.openPorts.join(", ")}');
      final mac = host.macAddress ?? _cachedMacs[host.ip];
      if (mac != null && mac.isNotEmpty) {
        result.writeln('  MAC hint: $mac (unverified)');
      }
    }
    result.writeln('---');
    result.write(_report.output);
    return result.toString();
  }

  Future<void> _copyNetworkDiagnostics() async {
    await Clipboard.setData(
        ClipboardData(text: _networkDiagnostics()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network diagnostics copied')));
    }
  }

  Future<void> _openHost(LanHost device) async {
    final matches = widget.knownComputers.where((entry) =>
        entry.host == device.ip && entry.macAddress.isNotEmpty);
    final mac = device.macAddress ?? _cachedMacs[device.ip] ??
        (matches.isEmpty ? null : matches.first.macAddress);
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => LanHostDetailsScreen(
        device: device,
        network: _network!,
        verifiedName: _verifiedAgents[device.ip],
        macAddress: mac,
        checkLg: _scanLg,
        checkSamsung: _scanSamsung,
      )),
    );
    // Only the explicit "Use IP for pairing" button returns to pairing;
    // regular Back leaves the existing network inventory untouched.
    if (selected != null && mounted) {
      Navigator.pop(context, selected);
    }
  }

  String _subtitle(LanHost device) {
    final matches = widget.knownComputers.where((e) =>
        e.host == device.ip && e.macAddress.isNotEmpty);
    final mac = device.macAddress ?? _cachedMacs[device.ip] ??
        (matches.isNotEmpty ? matches.first.macAddress : null);
    final verified = _verifiedAgents[device.ip];
    final model = _vendorModels[device.ip];
    return '${verified == null ? device.scanSubtitle : 'Paired: $verified · Verified agent'}'
        '${model == null ? '' : '\nModel hint: $model'}'
        '${mac == null || mac.isEmpty ? '' : '\nMAC: $mac'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan local network'),
        actions: [
          IconButton(
            key: const ValueKey('copy-network-report'),
            tooltip: 'Copy network diagnostics',
            onPressed: _copyNetworkDiagnostics,
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Choose what to scan on your current Wi-Fi. '
            'Vendor checks are optional read-only discovery, '
            'not pairing or remote control.'),
          const SizedBox(height: 12),
          if (_network != null) ...[
            Text('Phone Wi-Fi: ${_network!.ip} · Network: ${_network!.cidr}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (_network!.scanPrefixes.length > 1 &&
                _network!.scanPrefixes.length <= 8)
              CheckboxListTile(
                key: const ValueKey('scan-whole-network'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Scan entire Wi-Fi network'),
                subtitle: Text('${_network!.cidr} · '
                    '${_network!.scanPrefixes.length} ranges'),
                value: _scanWholeNetwork,
                onChanged: _busy ? null : (value) => setState(() {
                  _scanWholeNetwork = value ?? false;
                  if (_scanWholeNetwork) {
                    _scanTargetedIps = false;
                    _editedPrefix = false;
                    _prefix.text = _network!.activePrefix;
                  }
                }),
              ),
            if (_network!.scanPrefixes.length > 1 && !_scanTargetedIps)
              DropdownButtonFormField<String>(
                key: const ValueKey('lan-range-picker'),
                initialValue: _network!.scanPrefixes.contains(_prefix.text)
                    ? _prefix.text : _network!.activePrefix,
                decoration: const InputDecoration(
                  labelText: 'Choose nearby /24 scan range',
                  isDense: true,
                ),
                items: [
                  for (final value in _network!.scanPrefixes)
                    DropdownMenuItem(value: value, child: Text('$value.0/24')),
                ],
                onChanged: _busy ? null : (selected) {
                  if (selected != null) {
                    setState(() {
                      _editedPrefix = true;
                      _scanWholeNetwork = false;
                      _prefix.text = selected;
                    });
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _prefix,
            enabled: !_busy && !_scanTargetedIps,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {
              _editedPrefix = true;
              _scanWholeNetwork = false;
            }),
            decoration: const InputDecoration(
              labelText: 'Network prefix',
              hintText: '192.168.1',
              helperText: 'Detects the Wi-Fi subnet; you can also choose a /24 range.',
            ),
          ),
          const Divider(height: 24),
          Text('Scan options',
            style: Theme.of(context).textTheme.titleMedium),
          CheckboxListTile(
            key: const ValueKey('scan-targeted-only'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Specific IP addresses'),
            subtitle: const Text('Target one or more known devices'),
            value: _scanTargetedIps,
            onChanged: _busy ? null : (value) => setState(() {
              _scanTargetedIps = value ?? false;
              if (_scanTargetedIps) _scanWholeNetwork = false;
            }),
          ),
          CheckboxListTile(
            key: const ValueKey('scan-vendor-lg'),
            contentPadding: EdgeInsets.zero,
            title: const Text('LG'),
            subtitle: const Text('LG webOS hello, ports 3000/3001, '
                'appliance SSDP advertising'),
            value: _scanLg,
            onChanged: _busy ? null : (value) =>
                setState(() => _scanLg = value ?? false),
          ),
          CheckboxListTile(
            key: const ValueKey('scan-vendor-samsung'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Samsung'),
            subtitle: const Text('Read-only Tizen device metadata on 8001'),
            value: _scanSamsung,
            onChanged: _busy ? null : (value) =>
                setState(() => _scanSamsung = value ?? false),
          ),
          CheckboxListTile(
            key: const ValueKey('scan-deep-all-tcp'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Deep scan · TCP 1–65535'),
            subtitle: const Text('Advanced port scan. Slow, manual, '
                'cancellable; no login or remote commands'),
            value: _deepTcpPorts,
            onChanged: _busy ? null : (value) =>
                setState(() => _deepTcpPorts = value ?? false),
          ),
          if (_deepTcpPorts && !_scanTargetedIps)
            CheckboxListTile(
              key: const ValueKey('scan-deep-responsive-only'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Deep-scan responsive IPs only'),
              subtitle: const Text('Faster. Uncheck to scan every IP, '
                  'even devices with no common open ports.'),
              value: _deepOnlyResponsive,
              onChanged: _busy ? null : (value) =>
                  setState(() => _deepOnlyResponsive = value ?? false),
            ),
          if (_scanTargetedIps) ...[
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('scan-target-ips'),
              controller: _targetIps,
              enabled: !_busy,
              autocorrect: false,
              keyboardType: TextInputType.url,
              maxLines: 2,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Local IP addresses, comma-separated',
                hintText: '192.168.68.73, 192.168.68.53, 192.168.68.72'),
            ),
            const SizedBox(height: 8),
            if (_network != null &&
                lanRangeContains(_network!, '192.168.68.73') &&
                lanRangeContains(_network!, '192.168.68.53') &&
                lanRangeContains(_network!, '192.168.68.72'))
              Wrap(spacing: 7, runSpacing: 4, children: [
                ActionChip(
                  label: const Text('Washer'),
                  onPressed: _busy ? null : () => setState(
                      () => _targetIps.text = '192.168.68.73'),
                ),
                ActionChip(
                  label: const Text('Dryer'),
                  onPressed: _busy ? null : () => setState(
                      () => _targetIps.text = '192.168.68.53'),
                ),
                ActionChip(
                  label: const Text('Refrigerator'),
                  onPressed: _busy ? null : () => setState(
                      () => _targetIps.text = '192.168.68.72'),
                ),
                ActionChip(
                  label: const Text('All 3 LG appliances'),
                  onPressed: _busy ? null : () => setState(
                      () => _targetIps.text =
                          '192.168.68.73, 192.168.68.53, 192.168.68.72'),
                ),
              ]),
          ],
          const SizedBox(height: 12),
          if (_busy) ...[
            LinearProgressIndicator(
              value: _vendorBusy && _vendorTotal > 0
                  ? (_vendorChecked / _vendorTotal).clamp(0.0, 1.0)
                  : _deepTotal > 0
                      ? (_deepCompleted / _deepTotal).clamp(0.0, 1.0)
                      : (_completed / _total).clamp(0.0, 1.0)),
            const SizedBox(height: 10),
            Text(_vendorBusy
                ? 'Vendor checks: $_vendorChecked of $_vendorTotal IPs'
                : _deepTotal > 0
                    ? 'Deep TCP: $_deepCompleted/$_deepTotal ports'
                      '${_deepCurrentIp == null ? "" : " · $_deepCurrentIp"}'
                    : 'Checking $_completed of $_total addresses…'),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: () => _cancel = true,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop scan')),
          ] else
            FilledButton.icon(
              onPressed: _startScan,
              icon: const Icon(Icons.radar),
              label: Text(_deepTcpPorts
                  ? 'Start deep scan' : 'Start network scan'),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(
                color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 18),
          Text('Check a specific device',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('Quickly check one IP without using the advanced options '
              'above. LG webOS probes use TCP 3000/3001.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(
              key: const ValueKey('check-specific-ip'),
              controller: _specificIp,
              enabled: !_busy && !_checkingSpecificIp,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Device IP',
                hintText: '192.168.1.77',
              ),
            )),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _busy || _checkingSpecificIp
                  ? null : _checkSpecificIp,
              child: Text(_checkingSpecificIp ? 'Checking…' : 'Check IP'),
            ),
          ]),
          if (_specificPortResults.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('LG webOS connectivity',
                style: Theme.of(context).textTheme.titleSmall),
            for (final port in [3000, 3001])
              Text('TCP $port: ${tcpProbeLabel(_specificPortResults[port]!)}'),
            if (_lgProtocolResult != null) Text(_lgProtocolResult!),
            const Text('A refused connection means the host rejected the '
                'TCP connection; a timeout means no response arrived. '
                'Neither proves that the TV is powered off.'),
          ],
          if (_notRespondingIp != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('No tested services responded at $_notRespondingIp. '
                      'The device may still be online with its ports '
                      'closed. This is not proof that it is offline.'),
                  TextButton(
                    onPressed: () => Navigator.pop(context, _notRespondingIp),
                    child: const Text('Use this IP for pairing anyway'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          if (_verifiedAgents.isNotEmpty) ...[
            Text(
              '${_verifiedAgents.length} existing paired computer(s) verified',
              key: const ValueKey('scan-verified-pairs'),
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 8),
          ],
          Text('Devices found: ${_hosts.length}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!_busy && _hosts.isEmpty && _error == null)
            const Text('No devices detected yet. Some networks block discovery '
                'and devices with closed ports may not appear.'),
          for (final device in _hosts)
            Card(child: ListTile(
              leading: Icon(device.platform == 'darwin'
                  ? Icons.laptop_mac
                  : device.agentAnnounced || device.openPorts.contains(48321)
                      ? Icons.desktop_windows_outlined
                      : Icons.devices_other_outlined),
              title: Text(_verifiedAgents[device.ip] ?? device.displayName),
              subtitle: Text(_subtitle(device)),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              key: ValueKey('scan-device-${device.ip}'),
              onTap: _network == null ? null : () => _openHost(device),
            )),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const ValueKey('copy-network-diagnostics'),
            onPressed: _copyNetworkDiagnostics,
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Copy network diagnostics'),
          ),
          ScanReportPanel(
            title: 'Full Scan Output',
            report: _report,
          ),
          const SizedBox(height: 12),
          Text('MAC addresses come from paired agents or their LAN '
              'neighbor caches when available. They may be missing '
              'or stale, and do not prove a device is online.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          const Text('Tap a device to see its own scan options and report. '
              'Back returns to this device list without scanning again. '
              'Pairing requires a separate explicit action.'),
        ],
      )),
    );
  }
}
