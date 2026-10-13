import 'package:flutter/material.dart';
import 'computer_store.dart';
import 'discovery.dart';

/// Lists devices with previously verified TLS fingerprints and phone identity.
/// Discovery alone is never treated as trusted pairing.
class DeviceManagerScreen extends StatefulWidget {
  const DeviceManagerScreen({super.key, required this.store,
    required this.onConnect});
  final ComputerStore store;
  final Future<void> Function(SavedComputer) onConnect;
  @override
  State<DeviceManagerScreen> createState() => _DeviceManagerScreenState();
}

class _DeviceManagerScreenState extends State<DeviceManagerScreen> {
  List<SavedComputer> _computers = [];
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final updated = await widget.store.read();
      if (mounted) {
        setState(() {
          _computers = updated;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Cannot load saved computers: $e');
    }
  }

  Future<String?> _ask(String title, String label, String initial) async {
    final field = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: field, autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.pop(dialog, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, field.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    field.dispose();
    return value;
  }

  Future<void> _edit(SavedComputer device, {String? name, String? host}) async {
    if (_busy) return;
    final nextName = (name ?? device.name).trim();
    final nextHost = (host ?? device.host).trim();
    if (nextName.isEmpty || nextName.length > 80 ||
        !isPrivateIPv4(nextHost)) {
      setState(() => _error = 'Use a name (1–80 characters) and a private LAN IPv4 address.');
      return;
    }
    if (_computers.any((other) => other.id != device.id &&
        other.host == nextHost)) {
      setState(() => _error = 'Another saved device uses that IP address.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await widget.store.upsert(SavedComputer(
        id: device.id, name: nextName, host: nextHost,
        token: device.token, fingerprint: device.fingerprint,
        platform: device.platform, deviceId: device.deviceId,
      ));
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(SavedComputer device) async {
    final approved = await showDialog<bool>(context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Forget ${device.name}?'),
        content: const Text(
          'Erases this phone’s saved pairing data and TLS pin. '
          'The phone is not revoked on the computer. '
          'Revoke it separately using the agent controls if needed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Forget')),
        ],
      ),
    );
    if (approved != true || !mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.store.remove(device.id);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(SavedComputer device, String action) async {
    switch (action) {
      case 'connect':
        await widget.onConnect(device);
        if (mounted) Navigator.pop(context);
        return;
      case 'rename':
        final name = await _ask('Rename device', 'Display name', device.name);
        if (name != null && mounted) await _edit(device, name: name);
        return;
      case 'address':
        final host = await _ask('Update LAN address',
            'Private IPv4', device.host);
        if (host != null && mounted) await _edit(device, host: host);
        return;
      case 'forget':
        await _forget(device);
        return;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Manage Devices')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('${_computers.length} saved ${_computers.length == 1 ? 'computer' : 'computers'}',
          style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.add),
          label: const Text('Add computer'),
        )),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Padding(
          padding: const EdgeInsets.all(8),
          child: Text(_error!, style: TextStyle(
              color: Theme.of(context).colorScheme.error)),
        ),
        if (_computers.isEmpty) const Card(child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('No paired computers. Add one using verified '
            'agent pairing information or a QR code.'),
        )),
        for (final device in _computers)
          Card(child: ListTile(
            leading: Icon(device.platform == 'darwin'
                ? Icons.laptop_mac : Icons.computer),
            title: Text(device.name, maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: Text(device.host, maxLines: 1,
                overflow: TextOverflow.ellipsis),
            onTap: _busy ? null : () => _action(device, 'connect'),
            trailing: PopupMenuButton<String>(
              tooltip: 'Manage ${device.name}', enabled: !_busy,
              onSelected: (action) => _action(device, action),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'connect', child: Text('Connect')),
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'address', child: Text('Change LAN address')),
                PopupMenuItem(value: 'forget', child: Text('Forget device')),
              ],
            ),
          )),
        const SizedBox(height: 16),
        const Text('Saved connections retain their verified TLS fingerprint '
            'and authentication credentials. Changing an address does not '
            'silently trust a different computer.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    ),
  );
}
