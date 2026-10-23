import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lan_scan.dart';
import 'lg_appliance_discovery.dart';

/// Manual and independent from pairing, remote TV and ordinary LAN scanning.
class LgApplianceScanScreen extends StatefulWidget {
  const LgApplianceScanScreen({super.key});
  @override
  State<LgApplianceScanScreen> createState() => _LgApplianceScanScreenState();
}

class _LgApplianceScanScreenState extends State<LgApplianceScanScreen> {
  final _discovery = LgApplianceLanDiscovery();
  bool _busy = false;
  String? _error;
  String? _report;
  List<LgLanClue> _results = const [];

  Future<void> _scan() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final network = await detectLanRange();
      if (network == null) {
        throw StateError('Join your home Wi-Fi before scanning appliances.');
      }
      final result = await _discovery.scan(network);
      if (!mounted) return;
      setState(() {
        _results = result;
        _report = lgLanDiagnostic(network, result);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Local discovery unavailable. Check Wi-Fi and Local Network permission.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('LG Wi-Fi diagnostics')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text('Find LG appliances on your network',
          style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Separate from normal device discovery. TapTether '
          'will ask nearby devices for their advertised LG identity and '
          'model hints. No LG login or internet is needed.'),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('lg-lan-discover'),
          onPressed: _busy ? null : _scan,
          icon: const Icon(Icons.radar),
          label: Text(_busy ? 'Scanning Wi-Fi…' : 'Scan LG appliances'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(_error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (_report != null) ...[
          const SizedBox(height: 14),
          Text('Discovery results (${_results.length})',
              style: Theme.of(context).textTheme.titleMedium),
          if (_results.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No LG announcements detected. Some ThinQ '
                'appliances never advertise locally or may be asleep. '
                'Use the ThinQ API inventory for reliable model details.')),
          for (final item in _results)
            Card(child: ListTile(
              leading: const Icon(Icons.sensors),
              title: Text(item.name),
              subtitle: Text('IP: ${item.ip}\n'
                'Model hint: ${item.model.isEmpty ? 'Unavailable' : item.model}\n'
                'Server: ${item.server}'),
              isThreeLine: true,
            )),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('lg-copy-diagnostics'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _report!));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Diagnostic copied')));
              }
            },
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Copy diagnostic report'),
          ),
          const Text('The report contains local IP addresses and '
            'advertised device hints only. Review before sharing.'),
        ],
      ],
    ),
  );
}
