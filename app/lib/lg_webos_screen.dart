import 'dart:async';
import 'package:flutter/material.dart';
import 'lg_webos_client.dart';
import 'device_diagnostics_screen.dart';
import 'lg_compact_remote.dart';

/// Phone-side LG remote: on-screen controls only, no agent on the TV.
class LgWebOsScreen extends StatefulWidget {
  const LgWebOsScreen({super.key, this.initialHost,
    this.initialLocation = 'other', this.onSaved,
    this.autoReconnect = true, this.wakeDevice,
    this.lookupMacHint});
  final String? initialHost;
  final String initialLocation;
  final Future<void> Function()? onSaved;
  final bool autoReconnect;
  final Future<void> Function(LgTvDevice)? wakeDevice;
  /// Optional, explicit on-demand suggestion from an authenticated computer's
  /// neighbor table. ARP is unverified; user must review before saving.
  final Future<String?> Function(String host)? lookupMacHint;
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
  bool _waking = false;
  bool _discovering = false;
  String _status = 'Choose an LG TV on this Wi-Fi.';
  String? _error;

  bool get _detailMode => widget.initialHost != null;
  bool get _ready => !_busy && _session?.connected == true;
  // A device opened from My Devices MUST never fall back to some other TV.
  // Its saved identity is established by the exact tapped host on load;
  // verified TLS/UUID recovery may subsequently update that host.
  LgTvDevice? get _selected {
    if (_detailMode) return _connected ?? _target;
    return _connected ?? _target;
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
      final candidates = await discoverLgTvs(scanEntireLan: true);
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
          setState(() => _status = 'Selected ${_target!.name} · $host');
          if (widget.autoReconnect) await _recover(force: true);
        } else if (mounted) {
          setState(() {
            _status = 'This TV is no longer saved.';
            _error = 'Return to My Devices and select a saved TV.';
          });
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
    // Do not allow a detail route to switch to a different TV by accident.
    if (_detailMode && (_target == null ||
        (tv.host != _target!.host &&
        !(tv.deviceUuid.isNotEmpty &&
          tv.deviceUuid == _target!.deviceUuid) &&
        !(tv.tlsPin.isNotEmpty && tv.tlsPin == _target!.tlsPin)))) {
      return;
    }
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


  Future<void> _showDiagnostics(LgTvDevice tv) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeviceDiagnosticsScreen(
        name: tv.name, host: tv.host, kind: 'lg',
        location: tv.location, paired: tv.clientKey.isNotEmpty,
        hasTlsPin: tv.tlsPin.isNotEmpty,
        reportedOnline: _ready && _connected?.host == tv.host,
        model: tv.about['modelName'] ?? tv.about['model'] ?? '',
        about: tv.about, lastError: _error,
        verifyAuthenticated: tv.tlsPin.isEmpty ? null : () async {
          final valid = await matchesLgTlsPin(tv.host, tv.tlsPin);
          return {'TLS certificate identity': valid
              ? 'Matches saved fingerprint (no re-pairing)'
              : 'Not verified (certificate mismatch or TV unreachable)'};
        },
      ),
    ));
  }

  Future<void> _showAboutTv(LgTvDevice tv) async {
    // Refresh on demand if connected; previously captured information remains
    // readable while the TV is offline.
    if (_ready && _session != null && _connected?.host == tv.host) {
      await _identify(_session!, _connected!);
    }
    if (!mounted) return;
    final latest = _saved.where((item) =>
        item.host == tv.host ||
        (tv.tlsPin.isNotEmpty && item.tlsPin == tv.tlsPin));
    final details = latest.isEmpty ? tv : latest.first;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About TV'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              _aboutLine('Name', details.name),
              _aboutLine('IP address', details.host),
              _aboutLine('Connection', details.secure
                  ? 'Encrypted webOS LAN' : 'Legacy webOS LAN'),
              if (details.macAddress.isNotEmpty)
                _aboutLine('MAC address', details.macAddress),
              if (details.deviceUuid.isNotEmpty)
                _aboutLine('Device UUID', details.deviceUuid),
              if (details.about.isEmpty)
                const Text('Model and firmware information will be captured '
                    'when the paired TV responds to device information queries.'),
              for (final entry in details.about.entries)
                _aboutLine(entry.key, entry.value),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _aboutLine(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        SelectableText(value),
      ],
    ),
  );

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
    var checking = false;
    String? hint;
    final updated = await showDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, setDialogState) => AlertDialog(
          title: Text(tv.macAddress.isEmpty
              ? 'Set up Power On for ${tv.name}'
              : 'TV identity & power on'),
          content: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${tv.name} · ${tv.host}'),
              if (tv.deviceUuid.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('TV pairing identity saved',
                    style: TextStyle(fontSize: 12))),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('lg-mac-setup-field'),
                controller: controller,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'TV Wi-Fi MAC address',
                  hintText: 'AA:BB:CC:DD:EE:FF',
                  border: OutlineInputBorder(),
                ),
              ),
              if (widget.lookupMacHint != null) ...[
                const SizedBox(height: 6),
                TextButton.icon(
                  key: const ValueKey('lg-find-mac-hint'),
                  onPressed: checking ? null : () async {
                    setDialogState(() { checking = true; hint = null; });
                    try {
                      final candidate = await widget.lookupMacHint!(tv.host);
                      if (!dialog.mounted) {
                        return;
                      }
                      final normalized = canonicalLgMac(candidate ?? '');
                      setDialogState(() {
                        checking = false;
                        if (normalized == null) {
                          hint = 'No network MAC hint found. Enter it '
                              'from your router or TV settings.';
                        } else {
                          controller.text = normalized;
                          hint = 'Possible MAC from a paired computer. '
                              'Verify it belongs to this TV before saving.';
                        }
                      });
                    } catch (_) {
                      if (dialog.mounted) {
                        setDialogState(() {
                          checking = false;
                          hint = 'Could not retrieve a network MAC hint.';
                        });
                      }
                    }
                  },
                  icon: const Icon(Icons.search),
                  label: Text(checking
                      ? 'Checking paired computers…'
                      : 'Look up MAC on local network'),
                ),
              ],
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(hint!,
                      style: const TextStyle(fontSize: 12))),
              const SizedBox(height: 8),
              const Text('Find the Wi-Fi MAC in your router device '
                  'details, or on your LG TV under Settings → '
                  'All Settings → Support → TV Information '
                  '(on many newer models).',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              const Text('Enable TV On With Mobile / Turn on via Wi-Fi '
                  'on the television. Wake-on-LAN needs the MAC of '
                  'the network interface currently connected.',
                  style: TextStyle(fontSize: 12)),
            ],
          )),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Cancel')),
            FilledButton(
                key: const ValueKey('lg-save-mac'),
                onPressed: checking ? null
                    : () => Navigator.pop(dialog, controller.text.trim()),
                child: const Text('Save MAC')),
          ],
        ),
      ),
    );
    controller.dispose();
    if (updated == null || !mounted) {
      return;
    }
    final mac = canonicalLgMac(updated);
    if (updated.isNotEmpty && mac == null) {
      setState(() => _error = 'Enter a valid six-byte Wi-Fi MAC address.');
      return;
    }
    await _store.save(tv.copyWith(macAddress: mac ?? ''));
    await _reloadSaved();
    if (mounted) {
      setState(() => _error = null);
    }
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
    if (_detailMode && mounted) Navigator.of(context).pop();
  }

  /// Explicit device-specific wake never becomes a power-off operation
  /// if a background reconnect happens while the user presses On.
  Future<void> _wakeSelected() async {
    final current = _selected;
    if (current == null || _waking) {
      return;
    }
    if (_detailMode && _target != null &&
        current.host != _target!.host) {
      return;
    }
    // Don't pretend a failed wake occurred when setup is incomplete.
    // In the real app, an unknown MAC opens setup. Injected wake actions
    // keep existing isolation tests deterministic.
    if (canonicalLgMac(current.macAddress) == null &&
        widget.wakeDevice == null) {
      await _editMac(current);
      return;
    }
    _waking = true;
    try {
      await (widget.wakeDevice ?? wakeLgTv)(current);
      _suspended = false;
      if (mounted) {
        setState(() {
          _status = 'Power-on signal sent to ${current.name} (${current.host}).';
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      _waking = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _power() async {
    final current = _selected;
    if (current == null || _busy) {
      return;
    }
    if (_detailMode && _target != null &&
        current.host != _target!.host) {
      return;
    }
    if (!_ready || _connected?.host != current.host) {
      await _wakeSelected();
      return;
    }
    try {
      await _session!.powerOff();
      await _session!.disconnect();
      if (mounted) {
        setState(() {
          _connected = null;
          _suspended = true;
          _status = 'Power-off requested for ${current.name}';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
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
        title: Text(tv?.name ??
            (_detailMode ? 'Opening selected LG TV…' : 'LG webOS TV'),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          // In single-device mode the power target is named explicitly in
          // the body. Avoid an ambiguous generic "On" action in the header.
          if (tv != null && (!_detailMode || _ready))
            TextButton.icon(
              key: const ValueKey('lg-power-toggle'),
              onPressed: _busy || _recovering ? null : _power,
              icon: Icon(Icons.power_settings_new,
                  color: _ready ? Theme.of(context).colorScheme.error
                      : null),
              label: Text(_ready ? 'Off' : 'On'),
            ),
          if (tv != null)
            PopupMenuButton<String>(
              tooltip: 'TV options',
              onSelected: (item) {
                if (item == 'diagnostics') unawaited(_showDiagnostics(tv));
                if (item == 'about') unawaited(_showAboutTv(tv));
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
                const PopupMenuItem(value: 'diagnostics', child: Text('Diagnostics')),
                const PopupMenuItem(value: 'about', child: Text('About TV')),
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
          else if (_detailMode)
            Expanded(child: ListView(
              key: const ValueKey('lg-selected-tv-detail'),
              children: [
                if (tv == null)
                  const Card(child: ListTile(
                    leading: Icon(Icons.tv_off_outlined),
                    title: Text('Selected TV unavailable'),
                    subtitle: Text('Return to My Devices to select a saved TV.'),
                  ))
                else ...[
                  Card(child: ListTile(
                    key: const ValueKey('lg-selected-tv-card'),
                    leading: const Icon(Icons.tv_outlined, size: 28),
                    title: Text(tv.name),
                    subtitle: Text('IP: ${tv.host}\n'
                        '${_ready ? "Connected" : "Not connected"}'
                        '${tv.macAddress.isEmpty ? "" : " · MAC saved"}'),
                    isThreeLine: true,
                  )),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    key: const ValueKey('lg-power-selected-tv'),
                    onPressed: _waking ? null : _wakeSelected,
                    icon: const Icon(Icons.power_settings_new),
                    label: Text(_waking
                        ? 'Sending wake signal to ${tv.name}…'
                        : canonicalLgMac(tv.macAddress) == null
                            ? 'Set up Power On for ${tv.name}'
                            : 'Turn on ${tv.name}'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('lg-connect-selected-tv'),
                    onPressed: _busy || _recovering
                        ? null : () => _connect(tv),
                    icon: const Icon(Icons.link_outlined),
                    label: Text('Connect to ${tv.name}'),
                  ),
                  const SizedBox(height: 8),
                  Text(tv.macAddress.isEmpty
                      ? 'Power On needs this TV’s Wi-Fi MAC address. '
                        'Tap Set up Power On to save it once.'
                      : 'Power On sends a wake-up packet only to this '
                        'TV’s saved MAC address. Network standby must '
                        'be enabled on the TV.',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
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
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                     IconButton(
                       tooltip: 'Diagnostics',
                       icon: const Icon(Icons.bug_report_outlined),
                       onPressed: () => _showDiagnostics(paired),
                     ),
                     IconButton(
                       tooltip: 'Rename TV',
                       icon: const Icon(Icons.edit_outlined),
                       onPressed: () => _rename(paired),
                     ),
                   ]),
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
