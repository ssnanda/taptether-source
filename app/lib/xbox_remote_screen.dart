import 'dart:async';

import 'package:flutter/material.dart';

import 'discovery.dart';
import 'xbox_smartglass.dart';

/// First Xbox remote milestone: LAN discovery, saved consoles and standby wake.
/// Does NOT claim the console is authenticated or that buttons work yet.
class XboxRemoteScreen extends StatefulWidget {
  const XboxRemoteScreen({
    super.key,
    this.initialHost,
    this.initialLocation = 'other',
    this.onSaved,
    this.discovery,
    this.wake,
  });

  final String? initialHost;
  final String initialLocation;
  final Future<void> Function()? onSaved;
  final Future<List<XboxConsole>> Function({String? targetIp})? discovery;
  final Future<void> Function(XboxConsole)? wake;

  @override
  State<XboxRemoteScreen> createState() => _XboxRemoteScreenState();
}

class _XboxRemoteScreenState extends State<XboxRemoteScreen> {
  final _store = XboxConsoleStore();
  final _ip = TextEditingController();
  List<XboxConsole> _saved = [];
  List<XboxConsole> _found = [];
  XboxConsole? _selected;
  bool _busy = false;
  String _message = 'Discover your Xbox on the same Wi-Fi.';
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final devices = await _store.read();
      if (!mounted) return;
      setState(() {
        _saved = devices;
        if (widget.initialHost != null) {
          final matches = devices.where((d) => d.host == widget.initialHost);
          if (matches.isNotEmpty) {
            _selected = matches.first;
            _message = 'Saved Xbox — status not checked';
          } else {
            _error = 'This Xbox is no longer saved.';
          }
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Cannot read saved Xbox devices.');
    }
  }

  Future<void> _scan({String? ip}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = 'Searching on local Wi-Fi…';
    });
    try {
      final results = await (widget.discovery?.call(targetIp: ip) ??
          discoverXboxConsoles(targetIp: ip));
      if (!mounted) return;
      final stored = await _store.read();
      if (!mounted) return;
      setState(() {
        _saved = stored;
        _found = results;
        if (_selected != null) {
          final matches = results.where((item) =>
              item.uuid == _selected!.uuid &&
              item.certificateSha256 == _selected!.certificateSha256);
          if (matches.isNotEmpty) _selected = matches.first;
        }
        _message = results.isEmpty
            ? 'No SmartGlass discovery reply. Try Xbox LAN IP.'
            : 'Found ${results.length} Xbox console(s).';
      });
    } catch (error) {
      if (mounted) setState(() => _error =
          error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _byIp() async {
    final ip = _ip.text.trim();
    if (!isPrivateIPv4(ip)) {
      setState(() => _error = 'Enter a valid private IPv4 address.');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await _scan(ip: ip);
  }

  bool _sameIdentity(XboxConsole a, XboxConsole b) =>
      a.uuid == b.uuid && a.certificateSha256 == b.certificateSha256;

  Future<void> _save(XboxConsole device) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await _store.save(device.copyWith(location: widget.initialLocation));
      final stored = await _store.read();
      if (!mounted) return;
      setState(() {
        _selected = stored.firstWhere((e) => e.uuid == device.uuid);
        _saved = stored;
        _message = 'Xbox saved. This is discovery, not controller pairing.';
      });
      await widget.onSaved?.call();
    } catch (error) {
      if (mounted) setState(() => _error =
          error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _wake() async {
    if (_busy || _selected == null) return;
    final device = _selected!;
    final stored = _saved.where((saved) => _sameIdentity(saved, device));
    if (stored.isEmpty) {
      setState(() => _error = 'Save the Xbox before sending Wake.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await (widget.wake?.call(device) ?? wakeXbox(device));
      if (mounted) setState(() => _message =
          'Wake packets sent. This does not confirm that Xbox woke up.');
    } catch (error) {
      if (mounted) setState(() => _error =
          error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget() async {
    final device = _selected;
    if (device == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _store.remove(device.uuid);
      final stored = await _store.read();
      if (!mounted) return;
      setState(() {
        _saved = stored;
        _selected = null;
        _message = 'Xbox removed from My Devices.';
      });
      await widget.onSaved?.call();
    } catch (_) {
      if (mounted) setState(() => _error = 'Cannot remove saved Xbox.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final saved = selected != null &&
        _saved.any((d) => _sameIdentity(d, selected));
    return Scaffold(
      appBar: AppBar(title: const Text('Xbox Remote')),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) Card(child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!, style: TextStyle(
                color: Theme.of(context).colorScheme.error)),
          )),
          Text(_message, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          if (selected != null) Card(child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.videogame_asset_outlined, size: 38),
                  const SizedBox(width: 12),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(selected.name, style:
                            Theme.of(context).textTheme.titleLarge),
                        Text(selected.host),
                      ])),
                  if (saved) const Icon(Icons.bookmark_added_outlined),
                ]),
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (!saved) FilledButton.icon(
                    onPressed: _busy ? null : () => _save(selected),
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('Save Xbox'),
                  ),
                  if (saved) FilledButton.icon(
                    onPressed: _busy || selected.liveId.isEmpty
                        ? null : _wake,
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Wake Xbox'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _scan(ip: selected.host),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check connection'),
                  ),
                  if (saved) TextButton.icon(
                    onPressed: _busy ? null : _forget,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Forget'),
                  ),
                ]),
                const SizedBox(height: 12),
                Text(selected.liveId.isEmpty
                    ? 'Wake unavailable: Xbox did not provide a readable Live ID.'
                    : 'Wake needs Xbox Sleep/network standby enabled.',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          )),
          const SizedBox(height: 12),
          Card(child: ListTile(
            leading: const Icon(Icons.sports_esports_outlined),
            title: const Text('Controller and media buttons'),
            subtitle: const Text('Not yet enabled. Xbox requires an '
                'encrypted SmartGlass session before sending input.'),
          )),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : () => _scan(),
            icon: const Icon(Icons.radar),
            label: Text(_busy ? 'Searching…' : 'Discover Xbox on Wi-Fi'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ip,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Xbox LAN IP address',
              hintText: '192.168.1.100',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _byIp(),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _byIp,
            icon: const Icon(Icons.search),
            label: const Text('Find by IP'),
          ),
          if (widget.initialHost == null) ...[
            const SizedBox(height: 12),
            for (final device in _saved) ListTile(
              leading: const Icon(Icons.bookmark_outline),
              title: Text(device.name),
              subtitle: Text(device.host),
              onTap: _busy ? null : () =>
                  setState(() => _selected = device),
            ),
          ],
          for (final candidate in _found) ListTile(
            leading: const Icon(Icons.videogame_asset_outlined),
            title: Text(candidate.name),
            subtitle: Text(candidate.host),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : () =>
                setState(() => _selected = candidate),
          ),
          const SizedBox(height: 14),
          Text('Local-first preview · Xbox One / Series family. '
              'Discovery replies are unauthenticated. Verify the '
              'console in person before saving it. No Xbox account, '
              'cloud API or agent is used.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      )),
    );
  }

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }
}