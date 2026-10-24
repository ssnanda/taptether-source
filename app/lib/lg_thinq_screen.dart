import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'lg_thinq_api.dart';
import 'lg_thinq_device_screen.dart';

class LgThinQScreen extends StatefulWidget {
  const LgThinQScreen({super.key, this.initialDevice, this.onChanged});
  final LgThinQDevice? initialDevice;
  final Future<void> Function()? onChanged;

  @override
  State<LgThinQScreen> createState() => _LgThinQScreenState();
}

class _LgThinQScreenState extends State<LgThinQScreen> {
  final _store = LgThinQStorage();
  final _token = TextEditingController();
  String _country = 'US';
  bool _connected = false;
  bool _busy = false;
  String? _error;
  List<LgThinQDevice> _found = const [];
  List<LgThinQDevice> _enabled = const [];
  Map<String, String> _localNames = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object?>([
        _store.token(),
        _store.country(),
        _store.enabledDevices(),
        _store.localNames(),
      ]);
      if (!mounted) return;
      setState(() {
        _connected = (values[0] as String?)?.isNotEmpty == true;
        _country = values[1] as String;
        _enabled = values[2] as List<LgThinQDevice>;
        _localNames = values[3] as Map<String, String>;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not read secure ThinQ settings.');
      }
    }
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await task();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'ThinQ request failed. Check your '
            'token, device permissions and internet connection.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<LgThinQClient> _client({String? token}) async {
    final personalToken = token ?? await _store.token();
    if (personalToken == null || personalToken.isEmpty) {
      throw StateError('Connect your ThinQ account first.');
    }
    return LgThinQClient(
      personalToken: personalToken,
      country: _country,
      clientId: await _store.clientId(),
    );
  }

  Future<void> _connect() => _run(() async {
    final proposed = _token.text.trim();
    if (proposed.length < 20) {
      throw const FormatException('ThinQ token is missing.');
    }
    final api = await _client(token: proposed);
    final list = await api.discover();
    final names = await _store.localNames();
    await _store.configure(proposed, _country);
    if (!mounted) return;
    _token.clear();
    setState(() {
      _connected = true;
      _localNames = names;
      _found = list;
    });
  });

  Future<void> _discover() => _run(() async {
    final list = await (await _client()).discover();
    final names = await _store.localNames();
    if (mounted) setState(() {
      _found = list;
      _localNames = names;
    });
  });

  Future<void> _toggle(LgThinQDevice device, bool enabled) => _run(() async {
    await _store.setEnabled(device, enabled);
    final saved = await _store.enabledDevices();
    if (mounted) setState(() => _enabled = saved);
    await widget.onChanged?.call();
  });

  Future<void> _inspect(LgThinQDevice device) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LgThinQDeviceScreen(device: device),
    ));
  }

  Future<void> _disconnect() => _run(() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Disconnect LG ThinQ?'),
        content: const Text('Your ThinQ token and enabled cloud devices '
            'will be removed from TapTether. Local LG TV pairings stay saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Disconnect')),
        ],
      ),
    );
    if (approved != true) return;
    await _store.disconnect();
    if (!mounted) return;
    setState(() {
      _connected = false;
      _found = const [];
      _enabled = const [];
      _localNames = const {};
    });
    await widget.onChanged?.call();
  });

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listed = <String, LgThinQDevice>{
      for (final device in _enabled) device.id: device,
      for (final device in _found) device.id: device,
    }.values.map((device) => _localNames.containsKey(device.id)
        ? device.renamed(_localNames[device.id]!) : device).toList();
    final devices = listed.where((d) => !d.isTelevision).toList();
    final televisions = _found.where((d) => d.isTelevision).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('LG ThinQ integration')),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        Text('LG ThinQ · Cloud API',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Optional integration. Unlike TapTether’s local remote, '
            'this uses LG’s servers and requires internet. '
            'Cloud discovery is separate from normal Wi-Fi discovery. '
            'Only enabled devices appear in My Devices.'),
        const SizedBox(height: 10),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(_error!, style: TextStyle(
              color: Theme.of(context).colorScheme.error))),
        if (!_connected) ...[
          TextField(
            controller: _token,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'LG ThinQ personal access token',
              border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _country,
            decoration: const InputDecoration(
              labelText: 'LG account country',
              border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'US', child: Text('United States')),
              DropdownMenuItem(value: 'CA', child: Text('Canada')),
              DropdownMenuItem(value: 'IN', child: Text('India')),
              DropdownMenuItem(value: 'AU', child: Text('Australia')),
              DropdownMenuItem(value: 'GB', child: Text('United Kingdom')),
              DropdownMenuItem(value: 'DE', child: Text('Germany')),
            ],
            onChanged: _busy ? null : (value) {
              if (value != null) setState(() => _country = value);
            },
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _connect,
            icon: const Icon(Icons.link),
            label: const Text('Connect and discover LG devices'),
          ),
          TextButton.icon(
            onPressed: () => launchUrl(
              Uri.parse('https://connect-pat.lgthinq.com'),
              mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Create ThinQ personal access token'),
          ),
          const Text('Select device-list, profile and status permissions '
              'when creating your token. Tokens stay in secure storage; '
              'TapTether never stores your LG account password.'),
        ] else ...[
          Row(children: [
            const Icon(Icons.check_circle_outline, color: Colors.green),
            const SizedBox(width: 8),
            const Expanded(child: Text('LG ThinQ connected')),
            TextButton(onPressed: _busy ? null : _disconnect,
                child: const Text('Disconnect')),
          ]),
          FilledButton.tonalIcon(
            key: const ValueKey('thinq-cloud-discover'),
            onPressed: _busy ? null : _discover,
            icon: const Icon(Icons.cloud_sync_outlined),
            label: const Text('Discover ThinQ devices'),
          ),
          const SizedBox(height: 8),
          if (devices.isEmpty)
            const Text('Tap Discover to list devices in your LG account.'),
          if (televisions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('TVs seen by ThinQ · Preview',
                style: Theme.of(context).textTheme.titleMedium),
            const Text('Read-only account discovery. TVs are not '
                'imported, paired, or matched to a Wi-Fi address.'),
            for (final tv in televisions)
              Card(child: ListTile(
                leading: const Icon(Icons.tv_outlined),
                title: Text(tv.name),
                subtitle: Text(tv.model.isNotEmpty
                    ? tv.model : tv.type),
                trailing: const Icon(Icons.visibility_outlined),
              )),
          ],
          for (final device in devices)
            Card(child: Column(children: [
              SwitchListTile(
                key: ValueKey('thinq-enabled-${device.id}'),
                title: Text(device.name),
                subtitle: const Text('LG ThinQ appliance'),
                secondary: Icon(device.type.toUpperCase().contains('REFRIGERATOR')
                    ? Icons.kitchen_outlined :
                    device.type.toUpperCase().contains('DRYER')
                        ? Icons.dry_cleaning_outlined
                        : Icons.local_laundry_service_outlined),
                value: _enabled.any((item) => item.id == device.id),
                onChanged: _busy ? null : (value) => _toggle(device, value),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => _inspect(device),
                  icon: const Icon(Icons.info_outline),
                  label: const Text('Open all features'),
                ),
              ),
            ])),
        ],

      ]),
    );
  }
}
