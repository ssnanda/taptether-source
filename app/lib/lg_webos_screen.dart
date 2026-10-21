import 'dart:async';

import 'package:flutter/material.dart';

import 'lg_webos_client.dart';

/// Phone-side LG webOS remote. It does not install anything on the TV.
class LgWebOsScreen extends StatefulWidget {
  const LgWebOsScreen({
    super.key,
    this.initialHost,
    this.onSaved,
  });

  final String? initialHost;
  final Future<void> Function()? onSaved;

  @override
  State<LgWebOsScreen> createState() => _LgWebOsScreenState();
}

class _LgWebOsScreenState extends State<LgWebOsScreen> {
  final LgTvStore _store = LgTvStore();
  final TextEditingController _ip = TextEditingController();
  List<LgTvDevice> _saved = [];
  List<LgTvDevice> _discovered = [];
  List<({String id, String title})> _apps = [];
  LgWebOsClient? _session;
  LgTvDevice? _connected;
  bool _busy = false;
  bool _discovering = false;
  bool _muted = false;
  String _status = 'Choose an LG TV on the same Wi-Fi.';
  String? _error;
  String? _app;

  bool get _ready => !_busy && _session?.connected == true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final saved = await _store.read();
      if (!mounted) return;
      setState(() => _saved = saved);
      final host = widget.initialHost;
      if (host != null) {
        for (final tv in saved) {
          if (tv.host == host) {
            await _connect(tv);
            break;
          }
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Cannot read saved TV pairings.');
    }
  }

  Future<void> _discover() async {
    if (_discovering || _busy) return;
    setState(() {
      _discovering = true;
      _error = null;
      _status = 'Looking for LG webOS TVs on this Wi-Fi…';
    });
    try {
      final results = await discoverLgTvs();
      if (!mounted) return;
      setState(() {
        _discovered = results;
        _status = results.isEmpty
            ? 'No TV answered discovery. You can enter its LAN IP below.'
            : 'Select a TV to approve pairing on its screen.';
      });
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'TV discovery was blocked. Enter the TV IP manually.');
      }
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _connect(LgTvDevice tv) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = tv.clientKey.isEmpty
          ? 'Approve the TapTether pairing request on your LG TV.'
          : 'Connecting to ${tv.name}…';
    });
    final client = LgWebOsClient(tv);
    try {
      await _session?.disconnect();
      _session = null;
      _connected = null;
      final verified = await client.connect();
      await _store.save(verified);
      final saved = await _store.read();
      if (!mounted) {
        await client.disconnect();
        return;
      }
      setState(() {
        _saved = saved;
        _session = client;
        _connected = verified;
        _busy = false;
        _status = 'Connected · ${client.transport}';
      });
      await widget.onSaved?.call();
      try {
        final apps = await client.apps();
        if (mounted && _session == client) setState(() => _apps = apps);
      } catch (_) {
        // App listing is optional on older firmware; remote stays connected.
      }
    } catch (e) {
      await client.disconnect();
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString().replaceFirst('Bad state: ', '');
          _status = 'Not connected';
        });
      }
    }
  }

  Future<void> _manualConnect() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final host = _ip.text.trim();
    if (!validLgHost(host)) {
      setState(() => _error = 'Enter the TV private IPv4 address.');
      return;
    }
    final existing = _saved.where((tv) => tv.host == host);
    await _connect(existing.isNotEmpty
        ? existing.first : LgTvDevice(host: host, name: 'LG webOS TV'));
  }

  void _insertIpDot() {
    final text = _ip.text;
    final cursor = _ip.selection;
    final start = cursor.isValid ? cursor.start : text.length;
    final end = cursor.isValid ? cursor.end : text.length;
    _ip.value = TextEditingValue(
      text: text.replaceRange(start, end, '.'),
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  Future<void> _forget(LgTvDevice device) async {
    if (_connected?.host == device.host) {
      await _session?.disconnect();
      _session = null;
      _connected = null;
    }
    await _store.remove(device.host);
    await widget.onSaved?.call();
    if (!mounted) return;
    setState(() {
      _saved.removeWhere((tv) => tv.host == device.host);
      _status = 'TV pairing removed from this phone.';
    });
  }

  Future<void> _action(Future<void> Function(LgWebOsClient) action) async {
    final tv = _session;
    if (tv == null || !_ready) return;
    try {
      await action(tv);
      if (!mounted) return;
      setState(() => _error = null);
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Widget _key(String label, String command, IconData icon) =>
      IconButton.filledTonal(
        tooltip: label,
        icon: Icon(icon, size: 28),
        onPressed: _ready
            ? () => _action((client) => client.button(command))
            : null,
      );

  Widget _control(String label, IconData icon,
      Future<void> Function(LgWebOsClient) command) =>
      OutlinedButton.icon(
        onPressed: _ready ? () => _action(command) : null,
        icon: Icon(icon),
        label: Text(label),
      );

  Widget _remote() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(children: [
        Expanded(child: Text(_connected?.name ?? 'LG TV',
            style: Theme.of(context).textTheme.titleLarge)),
        TextButton.icon(
          onPressed: () async {
            await _session?.disconnect();
            if (mounted) {
              setState(() {
                _session = null;
                _connected = null;
                _apps = [];
                _app = null;
                _status = 'Disconnected';
              });
            }
          },
          icon: const Icon(Icons.link_off),
          label: const Text('Disconnect'),
        ),
      ]),
      const SizedBox(height: 8),
      Center(child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        children: [
          _control('Power off', Icons.power_settings_new,
              (tv) => tv.powerOff()),
          _control('Home', Icons.home_outlined,
              (tv) => tv.button('HOME')),
          _control('Back', Icons.arrow_back,
              (tv) => tv.button('BACK')),
        ],
      )),
      const SizedBox(height: 18),
      Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        _key('Up', 'UP', Icons.keyboard_arrow_up),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _key('Left', 'LEFT', Icons.keyboard_arrow_left),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _ready
                ? () => _action((tv) => tv.button('ENTER')) : null,
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: const EdgeInsets.all(22),
            ),
            child: const Text('OK'),
          ),
          const SizedBox(width: 8),
          _key('Right', 'RIGHT', Icons.keyboard_arrow_right),
        ]),
        _key('Down', 'DOWN', Icons.keyboard_arrow_down),
      ])),
      const SizedBox(height: 18),
      Wrap(
        alignment: WrapAlignment.spaceEvenly,
        runSpacing: 10,
        spacing: 8,
        children: [
          _control('Vol −', Icons.volume_down, (tv) => tv.volumeDown()),
          _control(_muted ? 'Unmute' : 'Mute',
              _muted ? Icons.volume_up : Icons.volume_off, (tv) async {
            await tv.mute(!_muted);
            if (mounted) setState(() => _muted = !_muted);
          }),
          _control('Vol +', Icons.volume_up, (tv) => tv.volumeUp()),
          _control('CH −', Icons.remove, (tv) => tv.channelDown()),
          _control('CH +', Icons.add, (tv) => tv.channelUp()),
        ],
      ),
      const SizedBox(height: 14),
      Wrap(alignment: WrapAlignment.spaceEvenly, spacing: 8, children: [
        _control('Rewind', Icons.fast_rewind, (tv) => tv.button('REWIND')),
        _control('Play', Icons.play_arrow, (tv) => tv.button('PLAY')),
        _control('Pause', Icons.pause, (tv) => tv.button('PAUSE')),
        _control('Forward', Icons.fast_forward,
            (tv) => tv.button('FASTFORWARD')),
      ]),
      if (_apps.isNotEmpty) ...[
        const SizedBox(height: 18),
        DropdownButtonFormField<String>(
          initialValue: _apps.any((item) => item.id == _app) ? _app : null,
          decoration: const InputDecoration(
              labelText: 'Launch installed TV app',
              border: OutlineInputBorder()),
          items: [
            for (final app in _apps)
              DropdownMenuItem(value: app.id,
                  child: Text(app.title, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: _ready ? (value) {
            if (value == null) return;
            setState(() => _app = value);
            _action((tv) => tv.launchApp(value));
          } : null,
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('LG webOS Remote')),
    body: SafeArea(child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_status, style: Theme.of(context).textTheme.bodyMedium),
        if (_busy || _discovering) const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: LinearProgressIndicator(),
        ),
        if (_error != null) Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
        if (_connected != null) ...[
          const SizedBox(height: 18),
          _remote(),
        ] else ...[
          const SizedBox(height: 12),
          if (_saved.isNotEmpty) ...[
            Text('Paired TVs', style: Theme.of(context).textTheme.titleMedium),
            for (final tv in _saved)
              Card(child: ListTile(
                leading: const Icon(Icons.tv),
                title: Text(tv.name),
                subtitle: Text(tv.host),
                enabled: !_busy,
                onTap: _busy ? null : () => _connect(tv),
                trailing: PopupMenuButton<String>(
                  tooltip: 'Manage TV',
                  onSelected: (action) {
                    if (action == 'forget') unawaited(_forget(tv));
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'forget',
                        child: Text('Forget pairing')),
                  ],
                ),
              )),
            const SizedBox(height: 16),
          ],
          FilledButton.icon(
            onPressed: (_busy || _discovering) ? null : _discover,
            icon: const Icon(Icons.radar),
            label: const Text('Discover LG TVs'),
          ),
          for (final tv in _discovered)
            ListTile(
              leading: const Icon(Icons.tv_outlined),
              title: Text(tv.name),
              subtitle: Text(tv.host),
              onTap: _busy ? null : () => _connect(
                _saved.where((known) => known.host == tv.host).firstOrNull ?? tv,
              ),
            ),
          const SizedBox(height: 20),
          TextField(
            controller: _ip,
            autocorrect: false,
            keyboardType: const TextInputType.numberWithOptions(
                decimal: true),
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Or enter TV LAN IP address',
              hintText: '192.168.1.100',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Insert IP address dot',
                icon: const Text('.',
                    style: TextStyle(fontSize: 28)),
                onPressed: _insertIpDot,
              ),
            ),
            onSubmitted: (_) => _manualConnect(),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _manualConnect,
            icon: const Icon(Icons.link),
            label: const Text('Pair by IP'),
          ),
          const SizedBox(height: 18),
          const Text('Keep your phone and TV on the same Wi-Fi. '
              'Approve the connection prompt on the TV once. '
              'No TV installation or Developer Mode is needed.'),
        ],
      ],
    )),
  );

  @override
  void dispose() {
    _ip.dispose();
    final client = _session;
    if (client != null) unawaited(client.disconnect());
    super.dispose();
  }
}
