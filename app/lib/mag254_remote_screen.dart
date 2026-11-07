import 'dart:async';
import 'package:flutter/material.dart';

import 'lan_scan.dart';
import 'mag254_protocol.dart';
import 'mag254_store.dart';
import 'tcl_google_tv_store.dart' show validTclGoogleTvHost;

class Mag254RemoteScreen extends StatefulWidget {
  const Mag254RemoteScreen({super.key, this.initialHost, this.onSaved,
    this.store, this.connectOverride});
  final String? initialHost;
  final Future<void> Function()? onSaved;
  final Mag254Store? store;
  final Future<void> Function(Mag254Device box)? connectOverride;
  @override
  State<Mag254RemoteScreen> createState() => _Mag254RemoteScreenState();
}

class _Mag254RemoteScreenState extends State<Mag254RemoteScreen> {
  late final Mag254Store _store = widget.store ?? Mag254Store();
  final _host = TextEditingController();
  final _name = TextEditingController(text: 'MAG254 IPTV Box');
  final _code = TextEditingController();
  List<Mag254Device> _saved = [];
  List<String> _found = [];
  Mag254Client? _client;
  Mag254Client? _pairing;
  bool _loading = true, _working = false, _connected = false;
  bool _settings = false, _success = false;
  String? _status;

  Mag254Device? get _selected {
    for (final box in _saved) {
      if (box.host == _host.text.trim()) return box;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialHost != null) _host.text = widget.initialHost!;
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final saved = await _store.read();
      if (!mounted) return;
      final match = saved.where((b) =>
          b.host == widget.initialHost).firstOrNull;
      setState(() {
        _saved = saved;
        if (match != null) _name.text = match.name;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() {
        _loading = false;
        _note('Could not load saved MAG254 devices.');
      });
    }
  }

  void _note(String message, {bool success = false}) {
    _status = message;
    _success = success;
  }

  void _disconnect() {
    _client?.close();
    _client = null;
    if (mounted) setState(() {
      _connected = false;
      _settings = false;
    });
  }

  Future<void> _save() async {
    if (_working) return;
    final host = _host.text.trim(), name = _name.text.trim();
    if (!validTclGoogleTvHost(host) || name.isEmpty || name.length > 80) {
      setState(() => _note('Enter a valid local MAG254 IP and name.'));
      return;
    }
    setState(() => _working = true);
    try {
      final saved = _selected?.copyWith(name: name) ??
          Mag254Device(host: host, name: name,
              deviceId: Mag254Protocol.newDeviceId());
      await _store.save(saved);
      final devices = await _store.read();
      if (!mounted) return;
      _disconnect();
      setState(() {
        _saved = devices;
        _note('Saved securely without connecting.', success: true);
      });
      await widget.onSaved?.call();
    } catch (_) {
      if (mounted) setState(() => _note('Could not save the MAG254.'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String?> _askCode() async {
    _code.clear();
    return showDialog<String>(
      context: context, barrierDismissible: false,
      builder: (dialog) => AlertDialog(
        title: const Text('Pair MAG254'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Enter the six-digit code shown on the MAG254. '
              'The optional Remote Control password can remain blank.'),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('mag254-code'), controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6, autofocus: true,
            decoration: const InputDecoration(
              labelText: 'TV pairing code', border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(onPressed: () =>
              Navigator.pop(dialog, _code.text.trim()),
              child: const Text('Pair')),
        ],
      ),
    );
  }

  Future<void> _pair() async {
    if (_working) return;
    final box = _selected;
    if (box == null) {
      setState(() => _note('Save the MAG254 first.'));
      return;
    }
    setState(() {
      _working = true;
      _note('Opening MAG254 pairing on TV…');
    });
    try {
      _disconnect();
      final client = Mag254Client(host: box.host, deviceId: box.deviceId);
      _pairing = client;
      await client.requestPairing();
      if (!mounted) return;
      final code = await _askCode();
      if (code == null) {
        setState(() => _note('Pairing cancelled; saved device retained.'));
        return;
      }
      if (!RegExp(r'^\d{6}$').hasMatch(code)) {
        setState(() => _note('Use the six-digit code shown on MAG254.'));
        return;
      }
      await client.confirmPairing(code);
      await _store.save(box.copyWith(pairingCode: code));
      final saved = await _store.read();
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _note('Paired. Tap Connect to open the remote.', success: true);
      });
      await widget.onSaved?.call();
    } catch (_) {
      if (mounted) setState(() => _note('Could not pair MAG254. '
          'Confirm its remote setting, Wi-Fi and pairing code.'));
    } finally {
      _pairing?.close();
      _pairing = null;
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _connect() async {
    if (_working) return;
    final box = _selected;
    if (box == null || !box.paired) {
      setState(() => _note('Save and pair the MAG254 first.'));
      return;
    }
    setState(() {
      _working = true;
      _note('Connecting to MAG254…');
    });
    try {
      _disconnect();
      if (widget.connectOverride != null) {
        await widget.connectOverride!(box);
      } else {
        final remote = Mag254Client(host: box.host,
            deviceId: box.deviceId, pairingCode: box.pairingCode);
        _client = remote;
        await remote.connectPaired();
      }
      if (!mounted) return;
      setState(() {
        _connected = true;
        _settings = false;
        _note('Connected to ${box.name}.', success: true);
      });
    } catch (_) {
      _client?.close();
      _client = null;
      if (mounted) setState(() => _note(
          'MAG254 connection failed. Verify IP and pairing.'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _send(int code) async {
    if (!_connected) return;
    try {
      await _client?.sendKey(code);
    } catch (_) {
      if (mounted) setState(() {
        _connected = false;
        _settings = true;
        _note('MAG254 disconnected. Reconnect from settings.');
      });
    }
  }

  Future<void> _scan() async {
    if (_working) return;
    setState(() {
      _working = true;
      _found = [];
      _note('Scanning this Wi-Fi for MAG remotes on port 40611…');
    });
    try {
      final lan = await detectLanRange();
      if (lan == null) {
        if (mounted) setState(() => _note('Connect to Wi-Fi first.'));
        return;
      }
      final targets = <String>[];
      for (final prefix in lan.scanPrefixes.take(4)) {
        for (var n = 1; n < 255; n++) {
          final host = '$prefix.$n';
          if (lanRangeContains(lan, host)) targets.add(host);
        }
      }
      final found = <String>[];
      var index = 0;
      Future<void> worker() async {
        while (index < targets.length) {
          final host = targets[index++];
          if (await mag254Responds(host)) found.add(host);
        }
      }
      await Future.wait(List.generate(24, (_) => worker()));
      found.sort();
      if (!mounted) return;
      setState(() {
        _found = found;
        _note(found.isEmpty ? 'No MAG remote service found.'
            : '${found.length} possible MAG service(s) found. '
              'Select, save and pair.',
              success: found.isNotEmpty);
      });
    } catch (_) {
      if (mounted) setState(() => _note(
          'Discovery failed. Enter the local MAG254 IP.'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _button(String label, IconData icon, int key) =>
      OutlinedButton.icon(
        onPressed: _connected ? () => unawaited(_send(key)) : null,
        icon: Icon(icon, size: 18), label: Text(label));

  Widget _arrow(String label, IconData icon, int key) =>
      IconButton.filledTonal(
        tooltip: label,
        onPressed: _connected ? () => unawaited(_send(key)) : null,
        icon: Icon(icon, size: 30));

  Widget _remotePad() => Card(child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 15),
    child: Column(children: [
      Wrap(spacing: 8, runSpacing: 6, alignment: WrapAlignment.center,
        children: [
          _button('Power', Icons.power_settings_new, Mag254Keys.power),
          _button('TV', Icons.tv, Mag254Keys.tv),
          _button('Info', Icons.info_outline, Mag254Keys.info),
        ]),
      const SizedBox(height: 12),
      _arrow('Up', Icons.keyboard_arrow_up, Mag254Keys.up),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _arrow('Left', Icons.keyboard_arrow_left, Mag254Keys.left),
        const SizedBox(width: 10),
        FilledButton(
          key: const ValueKey('mag254-ok'),
          onPressed: _connected
              ? () => unawaited(_send(Mag254Keys.ok)) : null,
          child: const Text('OK')),
        const SizedBox(width: 10),
        _arrow('Right', Icons.keyboard_arrow_right, Mag254Keys.right),
      ]),
      _arrow('Down', Icons.keyboard_arrow_down, Mag254Keys.down),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 7,
        alignment: WrapAlignment.center, children: [
          _button('Home', Icons.home, Mag254Keys.home),
          _button('Back', Icons.arrow_back, Mag254Keys.back),
          _button('Mute', Icons.volume_off, Mag254Keys.mute),
          _button('Vol −', Icons.volume_down, Mag254Keys.volumeDown),
          _button('Vol +', Icons.volume_up, Mag254Keys.volumeUp),
          _button('CH −', Icons.keyboard_arrow_down, Mag254Keys.channelDown),
          _button('CH +', Icons.keyboard_arrow_up, Mag254Keys.channelUp),
          _button('Play/Pause', Icons.play_arrow, Mag254Keys.playPause),
          _button('Rewind', Icons.fast_rewind, Mag254Keys.rewind),
          _button('Forward', Icons.fast_forward, Mag254Keys.fastForward),
        ]),
      const SizedBox(height: 10),
      Wrap(spacing: 7, runSpacing: 5,
        alignment: WrapAlignment.center, children: [
          _button('Red', Icons.circle, Mag254Keys.red),
          _button('Green', Icons.circle, Mag254Keys.green),
          _button('Yellow', Icons.circle, Mag254Keys.yellow),
          _button('Blue', Icons.circle, Mag254Keys.blue),
        ]),
      const Divider(height: 22),
      Wrap(spacing: 8, runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          for (var n = 1; n <= 9; n++)
            OutlinedButton(
              onPressed: _connected
                  ? () => unawaited(_send(Mag254Keys.digit(n))) : null,
              child: Text('$n')),
          OutlinedButton(
            onPressed: _connected
                ? () => unawaited(_send(Mag254Keys.digit(0))) : null,
            child: const Text('0')),
        ]),
    ]),
  ));

  Widget _remoteView() => SafeArea(child: Column(children: [
    Padding(
      padding: const EdgeInsets.fromLTRB(15, 6, 15, 0),
      child: Row(children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 17),
        const SizedBox(width: 8),
        Expanded(child: Text('Connected · ${_selected?.name ?? "MAG254"}',
            maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
    ),
    Expanded(child: ListView(
      key: const ValueKey('mag254-remote-view'),
      padding: const EdgeInsets.all(9),
      children: [_remotePad()],
    )),
  ]));

  @override
  Widget build(BuildContext context) {
    final saved = _selected;
    return Scaffold(
      appBar: AppBar(
        title: Text(_connected ? (saved?.name ?? 'MAG254')
            : 'MAG254 IPTV Remote'),
        actions: [
          if (_connected)
            IconButton(
              key: const ValueKey('mag254-settings-toggle'),
              tooltip: _settings ? 'Show remote' : 'Device settings',
              icon: Icon(_settings ? Icons.settings_remote : Icons.tune),
              onPressed: () => setState(() => _settings = !_settings),
            ),
          if (_connected)
            IconButton(
              tooltip: 'Disconnect', icon: const Icon(Icons.link_off),
              onPressed: _disconnect),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _connected && !_settings ? _remoteView()
          : ListView(
            key: const ValueKey('mag254-settings-view'),
            padding: const EdgeInsets.all(14),
            children: [
              Card(child: Padding(
                padding: const EdgeInsets.all(15),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('MAG254 / Infomir',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('mag254-host'),
                      controller: _host, enabled: !_working,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'MAG254 local IP',
                        hintText: '192.168.1.80'),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      key: const ValueKey('mag254-name'),
                      controller: _name, enabled: !_working,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Device name'),
                    ),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 7, children: [
                      OutlinedButton.icon(
                        key: const ValueKey('mag254-save'),
                        onPressed: _working ? null : () => unawaited(_save()),
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Save')),
                      OutlinedButton.icon(
                        key: const ValueKey('mag254-discover'),
                        onPressed: _working ? null : () => unawaited(_scan()),
                        icon: const Icon(Icons.radar),
                        label: const Text('Discover')),
                      FilledButton.icon(
                        key: const ValueKey('mag254-pair'),
                        onPressed: _working || saved == null ? null
                            : () => unawaited(_pair()),
                        icon: const Icon(Icons.phonelink_lock),
                        label: Text(saved?.paired == true
                            ? 'Pair again' : 'Pair')),
                      FilledButton.icon(
                        key: const ValueKey('mag254-connect'),
                        onPressed: _working || _connected ||
                            saved?.paired != true ? null
                            : () => unawaited(_connect()),
                        icon: const Icon(Icons.link),
                        label: const Text('Connect')),
                      if (_connected)
                        TextButton.icon(
                          key: const ValueKey('mag254-return-remote'),
                          onPressed: () => setState(() => _settings = false),
                          icon: const Icon(Icons.settings_remote),
                          label: const Text('Remote')),
                    ]),
                    if (_status != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 9),
                        child: Text(_status!,
                          style: TextStyle(color: _success
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.error)),
                      ),
                    if (_working) const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text('Enable Remote Control on MAG254 first. '
                        'The optional password can be blank. '
                        'Pair with the six-digit code shown on TV. '
                        'TCP 40611; Save works offline.',
                        style: Theme.of(context).textTheme.bodySmall),
                  ]),
              )),
              if (_found.isNotEmpty)
                Card(child: Column(children: [
                  const ListTile(title: Text('MAG remote services')),
                  for (final ip in _found)
                    ListTile(
                      title: Text(ip), trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        _disconnect();
                        _host.text = ip;
                        _name.text = _selected?.name ?? 'MAG254 IPTV Box';
                        setState(() => _note('Selected $ip. Save and pair.'));
                      }),
                ])),
              if (_saved.isNotEmpty)
                Card(child: Column(children: [
                  const ListTile(title: Text('Saved MAG IPTV boxes')),
                  for (final box in _saved)
                    ListTile(
                      key: ValueKey('mag254-saved-${box.deviceId}'),
                      dense: true, leading: const Icon(Icons.live_tv),
                      title: Text(box.name),
                      subtitle: Text('${box.host} · '
                          '${box.paired ? "Paired" : "Not paired"}'),
                      onTap: () {
                        _disconnect();
                        _host.text = box.host;
                        _name.text = box.name;
                        setState(() => _note('Selected ${box.name}.',
                            success: true));
                      },
                      trailing: IconButton(
                        tooltip: 'Remove saved MAG254',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _working ? null : () async {
                          _disconnect();
                          await _store.remove(box);
                          final updated = await _store.read();
                          if (!mounted) return;
                          setState(() {
                            _saved = updated;
                            if (_host.text.trim() == box.host) _host.clear();
                            _note('MAG254 removed.', success: true);
                          });
                          await widget.onSaved?.call();
                        }),
                    ),
                ])),
            ]),
    );
  }

  @override
  void dispose() {
    _pairing?.close();
    _client?.close();
    _host.dispose();
    _name.dispose();
    _code.dispose();
    super.dispose();
  }
}
