import 'dart:async';
import 'package:flutter/material.dart';
import 'lg_webos_client.dart';
import 'lg_compact_remote.dart';

/// Phone-side LG remote: on-screen controls only, no agent on the TV.
class LgWebOsScreen extends StatefulWidget {
  const LgWebOsScreen({super.key, this.initialHost,
    this.initialLocation = 'other', this.onSaved});
  final String? initialHost;
  final String initialLocation;
  final Future<void> Function()? onSaved;
  @override
  State<LgWebOsScreen> createState() => _LgWebOsScreenState();
}

class _LgWebOsScreenState extends State<LgWebOsScreen>
    with WidgetsBindingObserver {
  final _store = LgTvStore();
  final _ip = TextEditingController();
  List<LgTvDevice> _saved = [];
  List<LgTvDevice> _discovered = [];
  LgWebOsClient? _session;
  LgTvDevice? _connected;
  LgTvDevice? _target;
  Timer? _connectionTimer;
  bool _foreground = true;
  bool _recovering = false;
  bool _healthChecking = false;
  bool _suspended = false;
  DateTime _lastRecovery = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;
  bool _discovering = false;
  String _status = 'Choose an LG TV on this Wi-Fi.';
  String? _error;

  bool get _ready => !_busy && _session?.connected == true;
  LgTvDevice? get _selected {
    if (_connected != null) return _connected;
    if (_target != null) return _target;
    if (widget.initialHost != null) {
      for (final tv in _saved) {
        if (tv.host == widget.initialHost) return tv;
      }
    }
    return _saved.isEmpty ? null : _saved.first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
    _connectionTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted || !_foreground || _busy || _recovering ||
          _suspended) { return; }
      if (_ready) {
        unawaited(_checkSession());
      } else if (_selected?.clientKey.isNotEmpty == true) {
        unawaited(_recover());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && !_suspended &&
        _selected?.clientKey.isNotEmpty == true) {
      if (_ready) {
        unawaited(_checkSession());
      } else {
        unawaited(_recover(force: true));
      }
    }
  }

  /// A socket can remain nominally open after Wi-Fi changes. Check the
  /// authenticated channel, not merely WebSocket.readyState.
  Future<void> _checkSession() async {
    final client = _session;
    if (client == null || !client.connected || _healthChecking ||
        _busy || _recovering || !_foreground || _suspended) { return; }
    _healthChecking = true;
    try {
      await client.request(
          'ssap://com.webos.applicationManager/getForegroundAppInfo');
    } catch (_) {
      if (!mounted || _session != client || _suspended) return;
      await client.disconnect();
      if (!mounted || _session != client || _suspended) return;
      setState(() {
        _session = null;
        _connected = null;
        _status = 'Connection interrupted · recovering…';
      });
      unawaited(_recover(force: true));
    } finally {
      _healthChecking = false;
    }
  }

  /// Reuse the existing pairing key; never register an unknown TV on recovery.
  /// Only move an IP when a stable UUID or pinned TLS certificate matches.
  Future<void> _recover({bool force = false}) async {
    if (!mounted || !_foreground || _busy || _recovering ||
        _ready || _suspended) { return; }
    final tv = _selected;
    if (tv == null || tv.clientKey.isEmpty) { return; }
    final now = DateTime.now();
    if (!force && now.difference(_lastRecovery) <
        const Duration(seconds: 90)) { return; }
    _lastRecovery = now;
    _recovering = true;
    try {
      if (mounted) { setState(() {
        _status = 'Reconnecting to ${tv.name}…';
        _error = null;
      }); }
      // IP is a last-known route, never the TV identity. TLS pin and saved
      // registration key are required to reuse a pairing at any address.
      // First try the last known address; most reconnects do not need a scan.
      if (await _tryRecoveryHost(tv, tv.host)) { return; }
      if (!mounted || !_foreground) { return; }
      if (mounted) { setState(() =>
          _status = 'Finding ${tv.name} on Wi-Fi…'); }
      final candidates = await discoverLgTvs();
      for (final candidate in candidates) {
        if (!mounted || !_foreground) { return; }
        if (candidate.host == tv.host) { continue; }
        final sameUuid = tv.deviceUuid.isNotEmpty &&
            candidate.deviceUuid.isNotEmpty &&
            tv.deviceUuid == candidate.deviceUuid;
        final sameTls = tv.tlsPin.isNotEmpty &&
            await matchesLgTlsPin(candidate.host, tv.tlsPin);
        // A MAC address is a discovery hint, not proof: iOS cannot query
        // arbitrary LAN MACs and MAC addresses can be spoofed. Only a pinned
        // certificate permits sending the saved client key to a new host.
        if (!sameUuid && !sameTls) { continue; }
        if (await _tryRecoveryHost(tv, candidate.host)) { return; }
      }
      if (mounted) { setState(() {
        _status = 'TV unavailable · will retry automatically';
        _error = null;
      }); }
    } finally {
      _recovering = false;
    }
  }

  Future<bool> _tryRecoveryHost(LgTvDevice tv, String host) async {
    // Never send a stored client key to an unverified new address.
    if (host != tv.host && tv.tlsPin.isNotEmpty &&
        !await matchesLgTlsPin(host, tv.tlsPin)) { return false; }
    if (host == tv.host && tv.tlsPin.isNotEmpty &&
        !await matchesLgTlsPin(host, tv.tlsPin)) { return false; }
    // Never migrate a stored key to a different IP without a trusted TLS pin.
    if (host != tv.host && tv.tlsPin.isEmpty) { return false; }
    final updated = tv.copyWith(host: host);
    final client = LgWebOsClient(updated);
    try {
      final paired = await client.connect();
      if (!mounted || !_foreground) {
        await client.disconnect();
        return false;
      }
      await _session?.disconnect();
      _session = client;
      _connected = paired;
      _target = paired;
      await _store.save(paired);
      if (!mounted) return false;
      setState(() {
        _status = 'Connected · ${client.transport}';
        _error = null;
      });
      await _reloadSaved();
      unawaited(_identify(client, paired));
      return true;
    } catch (_) {
      await client.disconnect();
      return false;
    }
  }

  Future<void> _load() async {
    try {
      final saved = await _store.read();
      if (!mounted) return;
      setState(() => _saved = saved);
      final host = widget.initialHost;
      if (host != null) {
        final matches = saved.where((tv) => tv.host == host);
        if (matches.isNotEmpty) {
          _target = matches.first;
          await _recover(force: true);
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
      _status = 'Searching this Wi-Fi for LG TVs…';
    });
    try {
      final candidates = await discoverLgTvs();
      if (mounted) {
        setState(() {
        _discovered = candidates;
        _status = candidates.isEmpty
            ? 'No TV found. Enter its local IP address.'
            : 'Choose your TV to pair.';

        });
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Discovery unavailable. Pair using the TV IP address.');
      }
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _connect(LgTvDevice tv) async {
    if (_busy || _recovering) return;
    _target = tv;
    _suspended = false;
    setState(() {
      _busy = true;
      _error = null;
      _status = tv.clientKey.isEmpty
          ? 'Approve TapTether on the TV screen.'
          : 'Connecting…';
    });
    final client = LgWebOsClient(tv.copyWith(
      location: tv.location == 'other'
          ? widget.initialLocation : tv.location,
    ));
    try {
      await _session?.disconnect();
      _session = null;
      _connected = null;
      final paired = await client.connect();
      await _store.save(paired);
      if (!mounted) {
        await client.disconnect();
        return;
      }
      setState(() {
        _session = client;
        _connected = paired;
        _target = paired;
        _busy = false;
        _status = 'Connected · ${client.transport}';
      });
      await _reloadSaved();
      // Optional identifiers must not delay opening the remote.
      unawaited(_identify(client, paired));
    } catch (error) {
      await client.disconnect();
      if (mounted) {
        setState(() {
        _busy = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
        _status = 'Not connected';

        });
      }
    }
  }

  Future<void> _identify(LgWebOsClient client, LgTvDevice paired) async {
    try {
      final details = await client.identify(paired);
      if (!mounted || _session != client) return;
      await _store.save(details);
      await _reloadSaved();
    } catch (_) {
      // Naming and control still work if TV identifier APIs are unavailable.
    }
  }

  Future<void> _reloadSaved() async {
    final devices = await _store.read();
    if (mounted) {
      setState(() {
      _saved = devices;
      if (_connected != null) {
        for (final item in devices) {
          if (item.host == _connected!.host) {
            _connected = item;
            break;
          }
        }
      }
      if (_target != null) {
        for (final item in devices) {
          if (item.host == _target!.host ||
              (_target!.deviceUuid.isNotEmpty &&
                  item.deviceUuid == _target!.deviceUuid) ||
              (_target!.tlsPin.isNotEmpty &&
                  item.tlsPin == _target!.tlsPin)) {
            _target = item;
            break;
          }
        }
      }

      });
    }
    await widget.onSaved?.call();
  }

  Future<void> _manualConnect() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final ip = _ip.text.trim();
    if (!validLgHost(ip)) {
      setState(() => _error = 'Enter the TV private IPv4 address.');
      return;
    }
    final saved = _saved.where((tv) => tv.host == ip);
    await _connect(saved.isNotEmpty ? saved.first :
        LgTvDevice(host: ip, name: 'LG webOS TV'));
  }

  void _insertIpDot() {
    final selection = _ip.selection;
    final start = selection.isValid ? selection.start : _ip.text.length;
    final end = selection.isValid ? selection.end : _ip.text.length;
    _ip.value = TextEditingValue(
      text: _ip.text.replaceRange(start, end, '.'),
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  Future<void> _rename(LgTvDevice tv) async {
    final controller = TextEditingController(
      text: tv.name == 'LG webOS TV' ? '' : tv.name,
    );
    final updated = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Name this TV'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'TV nickname',
            hintText: 'Family Room TV',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // The dialog is closed; the new nickname is local to this iPhone.
    controller.dispose();
    if (updated == null || updated.isEmpty || !mounted) return;
    await _store.save(tv.copyWith(name: updated));
    await _reloadSaved();
  }

  Future<void> _editMac(LgTvDevice tv) async {
    final controller = TextEditingController(text: tv.macAddress);
    final updated = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('TV identity & power on'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Local IP: ${tv.host}'),
          if (tv.deviceUuid.isNotEmpty)
            Text('TV ID: ${tv.deviceUuid}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'TV MAC address',
              hintText: 'AA:BB:CC:DD:EE:FF',
            ),
          ),
          const SizedBox(height: 8),
          const Text('Enable Mobile TV On / Wake-on-LAN on the TV '
              'for supported models.',
              style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(onPressed: () =>
              Navigator.pop(dialog, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (updated == null || !mounted) return;
    final mac = canonicalLgMac(updated);
    if (updated.isNotEmpty && mac == null) {
      setState(() => _error = 'Enter a valid six-byte MAC address.');
      return;
    }
    await _store.save(tv.copyWith(macAddress: mac ?? ''));
    await _reloadSaved();
  }

  Future<void> _forget(LgTvDevice tv) async {
    if (_connected?.host == tv.host) {
      await _session?.disconnect();
      _session = null;
      _connected = null;
    }
    await _store.remove(tv.host);
    if (_target?.host == tv.host) _target = null;
    await _reloadSaved();
  }

  Future<void> _power() async {
    final current = _selected;
    if (current == null || _busy) return;
    if (_ready) {
      try {
        await _session!.powerOff();
        await _session!.disconnect();
        if (mounted) {
          setState(() {
          _connected = null;
          _suspended = true;
          _status = 'Power-off requested';

          });
        }
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
      }
    } else {
      try {
        await wakeLgTv(current);
        _suspended = false;
        if (mounted) {
          setState(() {
          _status = 'Power-on signal sent. TV may take a moment.';
          _error = null;

          });
        }
      } catch (error) {
        if (mounted) {
          setState(() =>
              _error = error.toString().replaceFirst('Bad state: ', ''));
        }
      }
    }
  }

  Future<void> _disconnect() async {
    _suspended = true;
    await _session?.disconnect();
    if (mounted) {
      setState(() {
      _session = null;
      _connected = null;
      _status = 'Disconnected';

      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tv = _selected;
    return Scaffold(
      appBar: AppBar(
        title: Text(tv?.name ?? 'LG webOS TV',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (tv != null)
            TextButton.icon(
              key: const ValueKey('lg-power-toggle'),
              onPressed: _busy ? null : _power,
              icon: Icon(Icons.power_settings_new,
                  color: _ready ? Theme.of(context).colorScheme.error
                      : null),
              label: Text(_ready ? 'Off' : 'On'),
            ),
          if (tv != null)
            PopupMenuButton<String>(
              tooltip: 'TV options',
              onSelected: (item) {
                if (item == 'rename') unawaited(_rename(tv));
                if (item == 'mac') unawaited(_editMac(tv));
                if (item == 'disconnect') unawaited(_disconnect());
                if (item == 'forget') unawaited(_forget(tv));
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'rename', child: Text('Rename TV')),
                const PopupMenuItem(
                    value: 'mac', child: Text('TV identity / MAC')),
                if (_ready) const PopupMenuItem(
                    value: 'disconnect', child: Text('Disconnect')),
                const PopupMenuItem(
                    value: 'forget', child: Text('Forget TV')),
              ],
            ),
        ],
      ),
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(children: [
          Row(children: [
            Icon(_ready ? Icons.check_circle : Icons.circle_outlined,
                color: _ready ? Colors.green : null, size: 15),
            const SizedBox(width: 8),
            Expanded(child: Text(_status,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall)),
          ]),
          if (_busy || _discovering)
            const LinearProgressIndicator(),
          if (_error != null) Text(_error!,
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Theme.of(context).colorScheme.error,
                fontSize: 12)),
          const SizedBox(height: 8),
          if (_ready && _connected != null)
            Expanded(child: LgCompactRemote(
              key: ValueKey(_connected!.host),
              client: _session!, device: _connected!,
              captureSnapshot: _session!.takeSnapshot,
              onError: (error) {
                if (mounted) setState(() => _error = error);
              },
            ))
          else
            Expanded(child: ListView(children: [
              for (final paired in _saved)
                Card(child: ListTile(
                  leading: const Icon(Icons.tv_outlined),
                  title: Text(paired.name),
                  subtitle: Text(paired.host +
                      (paired.macAddress.isEmpty ? '' : ' · MAC saved')),
                  onTap: _busy ? null : () => _connect(paired),
                  trailing: IconButton(
                    tooltip: 'Rename TV',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _rename(paired),
                  ),
                )),
              FilledButton.icon(
                onPressed: _busy || _discovering ? null : _discover,
                icon: const Icon(Icons.radar),
                label: const Text('Discover LG TVs'),
              ),
              for (final candidate in _discovered)
                ListTile(
                  leading: const Icon(Icons.tv),
                  title: Text(candidate.name),
                  subtitle: Text(candidate.host),
                  onTap: _busy ? null : () {
                    final matches = _saved.where(
                        (tv) => tv.host == candidate.host);
                    unawaited(_connect(matches.isNotEmpty
                        ? matches.first : candidate));
                  },
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _ip,
                autocorrect: false,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Or enter TV IP',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Insert IP address dot',
                    onPressed: _insertIpDot,
                    icon: const Text('.',
                      style: TextStyle(fontSize: 27)),
                  ),
                ),
                onSubmitted: (_) => _manualConnect(),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _manualConnect,
                icon: const Icon(Icons.link),
                label: const Text('Pair by IP'),
              ),
            ])),
        ]),
      )),
    );
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _ip.dispose();
    if (_session != null) unawaited(_session!.disconnect());
    super.dispose();
  }
}
