import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'lan_scan.dart';
import 'tcl_google_tv_store.dart';
import 'tcl_google_tv_protocol/certificate.dart';
import 'tcl_google_tv_protocol/key_codes.dart';
import 'tcl_google_tv_protocol/pairing_client.dart';
import 'tcl_google_tv_protocol/pairing_secret.dart';
import 'tcl_google_tv_protocol/remote_client.dart';

/// TCL sets running Google TV: local Remote Service v2 over TLS.
class TclGoogleTvScreen extends StatefulWidget {
  const TclGoogleTvScreen({
    super.key,
    this.initialHost,
    this.onSaved,
    this.store,
    this.connectOverride,
  });

  final String? initialHost;
  final Future<void> Function()? onSaved;
  final TclGoogleTvStore? store;
  /// Allows connection-view widget tests without contacting a physical TV.
  final Future<void> Function(TclGoogleTv tv)? connectOverride;

  @override
  State<TclGoogleTvScreen> createState() => _TclGoogleTvScreenState();
}

class _TclGoogleTvScreenState extends State<TclGoogleTvScreen> {
  late final TclGoogleTvStore _store = widget.store ?? TclGoogleTvStore();
  final _host = TextEditingController();
  final _name = TextEditingController(text: 'TCL Google TV');
  final _code = TextEditingController();
  List<TclGoogleTv> _saved = [];
  List<String> _found = [];
  RemoteClient? _remote;
  PairingClient? _pairing;
  StreamSubscription<RemoteConnectionState>? _remoteStatus;
  bool _working = false;
  bool _connected = false;
  bool _showSettings = false;
  bool _loading = true;
  String? _message;
  bool _ok = false;

  TclGoogleTv? get _selected {
    final host = _host.text.trim();
    for (final tv in _saved) {
      if (tv.host == host) return tv;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialHost != null) _host.text = widget.initialHost!;
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final entries = await _store.read();
      if (!mounted) return;
      final wanted = widget.initialHost;
      final selected = entries.where((tv) => tv.host == wanted).firstOrNull;
      setState(() {
        _saved = entries;
        if (selected != null) _name.text = selected.name;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _setResult('Cannot load TV pairings from iPhone Keychain.');
        });
      }
    }
  }

  void _setResult(String value, {bool success = false}) {
    _message = value;
    _ok = success;
  }

  void _disconnect() {
    unawaited(_remoteStatus?.cancel());
    _remoteStatus = null;
    _remote?.dispose();
    _remote = null;
    if (mounted) {
      setState(() {
        _connected = false;
        _showSettings = false;
      });
    }
  }

  Future<void> _save() async {
    if (_working) return;
    final host = _host.text.trim();
    final name = _name.text.trim();
    if (!validTclGoogleTvHost(host) || name.isEmpty || name.length > 80) {
      setState(() => _setResult('Enter a private local TV IP and name.'));
      return;
    }
    setState(() => _working = true);
    try {
      final existing = _selected;
      await _store.save(existing?.copyWith(name: name) ??
          TclGoogleTv(host: host, name: name));
      final saved = await _store.read();
      if (!mounted) return;
      _disconnect();
      setState(() {
        _saved = saved;
        _setResult('Saved locally. Pair or connect whenever you want.',
            success: true);
      });
      await widget.onSaved?.call();
    } catch (_) {
      if (mounted) {
        setState(() => _setResult('Could not save TV in iPhone Keychain.'));
      }
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<void> _remove() async {
    final selected = _selected;
    if (selected == null || _working) return;
    setState(() => _working = true);
    try {
      _disconnect();
      await _store.remove(selected.host);
      final saved = await _store.read();
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _host.clear();
        _name.text = 'TCL Google TV';
        _setResult('TV removed from saved devices.', success: true);
      });
      await widget.onSaved?.call();
    } catch (_) {
      if (mounted) {
        setState(() => _setResult('Could not remove saved TV.'));
      }
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<String?> _askCode() async {
    _code.clear();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => AlertDialog(
        title: const Text('Pair TCL Google TV'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Enter the 6-character code displayed on the TV.'),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('tcl-pairing-code'),
            controller: _code,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            maxLength: 6,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'TV pairing code',
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(onPressed: () =>
              Navigator.pop(dialog, _code.text.trim().toUpperCase()),
              child: const Text('Pair')),
        ],
      ),
    );
  }

  Future<void> _pair() async {
    if (_working) return;
    final selected = _selected;
    if (selected == null) {
      setState(() => _setResult('Save the TV first, then select Pair.'));
      return;
    }
    setState(() {
      _working = true;
      _setResult('Opening the TV pairing screen…');
    });
    try {
      _disconnect();
      // Pairing must use the same private key and certificate later used for
      // control. Nothing is sent to a cloud service or external bridge.
      final identity = ClientCertificate.generate();
      final pairing = PairingClient(
        host: selected.host, cert: identity, clientName: 'TapTether',
      );
      _pairing = pairing;
      await pairing.start();
      if (!mounted) return;
      final code = await _askCode();
      if (code == null) {
        setState(() => _setResult('Pairing cancelled; saved TV retained.'));
        return;
      }
      if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(code)) {
        setState(() => _setResult('Enter the 6-character TV pairing code.'));
        return;
      }
      await pairing.finish(code);
      final serverFingerprint = pairing.serverFingerprint ?? '';
      if (serverFingerprint.length != 64) {
        throw StateError('TV certificate was not verified');
      }
      await _store.save(selected.copyWith(
        certificatePem: identity.certificatePem,
        privateKeyPem: identity.privateKeyPem,
        serverFingerprint: serverFingerprint,
      ));
      final saved = await _store.read();
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _setResult('Paired successfully. Tap Connect to control your TV.',
            success: true);
      });
      await widget.onSaved?.call();
    } on PairingCodeError catch (error) {
      if (mounted) {
        setState(() => _setResult(error.toString()));
      }
    } on PairingException catch (error) {
      if (mounted) {
        setState(() => _setResult(error.toString()));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _setResult('Could not pair. Ensure Google TV Remote '
            'Service is running and your phone is on the same Wi-Fi.'));
      }
    } finally {
      _pairing?.dispose();
      _pairing = null;
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<void> _connect() async {
    if (_working) return;
    final selected = _selected;
    if (selected == null || !selected.paired) {
      setState(() => _setResult('Save and pair this TV first.'));
      return;
    }
    setState(() {
      _working = true;
      _setResult('Connecting to Google TV Remote Service…');
    });
    try {
      _disconnect();
      // The real app uses the pinned Google TV TLS session. Tests supply
      // a fake handshake to verify the remote-only navigation transition.
      if (widget.connectOverride != null) {
        await widget.connectOverride!(selected);
        if (!mounted) return;
        setState(() {
          _connected = true;
          _showSettings = false;
          _setResult('Connected to ${selected.name}.', success: true);
        });
        return;
      }
      final ctx = SecurityContext(withTrustedRoots: false);
      ctx.useCertificateChainBytes(utf8.encode(selected.certificatePem));
      ctx.usePrivateKeyBytes(utf8.encode(selected.privateKeyPem));
      final client = RemoteClient(
        host: selected.host,
        context: ctx,
        expectedFingerprint: selected.serverFingerprint,
      );
      await client.connect();
      if (!mounted) {
        client.dispose();
        return;
      }
      _remote = client;
      _remoteStatus = client.stateStream.listen((status) {
        if (status == RemoteConnectionState.disconnected && mounted) {
          setState(() {
            _connected = false;
            _showSettings = false;
            _setResult('TV disconnected. Tap Connect again.');
          });
        }
      });
      setState(() {
        _connected = true;
        _showSettings = false;
        _setResult('Connected to ${selected.name}.', success: true);
      });
    } on RemoteNotPairedException {
      if (mounted) {
        setState(() => _setResult('The TV rejected its saved certificate. Tap Pair again.'));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _setResult('Cannot connect on TCP 6466. Check the TV IP, '
              'Wi-Fi, and Google TV Remote Service.'));
      }
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  void _send(int key) {
    if (!_connected || _remote == null) return;
    try {
      _remote!.sendKey(key);
    } catch (_) {
      if (mounted) {
        setState(() => _setResult('TV command could not be sent.'));
      }
    }
  }

  Future<void> _scan() async {
    if (_working) return;
    setState(() {
      _working = true;
      _found = [];
      _setResult('Scanning the current Wi-Fi for Google TV pairing ports…');
    });
    try {
      final lan = await detectLanRange();
      if (lan == null) {
        if (mounted) {
          setState(() => _setResult('Connect your iPhone to Wi-Fi to discover TVs.'));
        }
        return;
      }
      final targets = <String>[];
      for (final prefix in lan.scanPrefixes.take(4)) {
        for (var last = 1; last <= 254; last++) {
          targets.add('$prefix.$last');
        }
      }
      final found = <String>[];
      var next = 0;
      Future<void> worker() async {
        while (next < targets.length) {
          final host = targets[next++];
          try {
            final socket = await Socket.connect(host, 6467,
                timeout: const Duration(milliseconds: 400));
            socket.destroy();
            found.add(host);
          } catch (_) {
            // No pairing listener. This host is not advertised as a TV.
          }
        }
      }
      await Future.wait(List.generate(28, (_) => worker()));
      found.sort();
      if (!mounted) return;
      setState(() {
        _found = found;
        _setResult(found.isEmpty ? 'No Google TV pairing ports found.'
            : '${found.length} device(s) with port 6467 reachable. '
                'Select your TCL TV, save, then pair.',
            success: found.isNotEmpty);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _setResult('Could not scan this Wi-Fi. Enter the TV IP.'));
      }
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Widget _keyButton(String label, IconData icon, int key,
      {Key? keyId}) => OutlinedButton.icon(
    key: keyId,
    onPressed: _connected ? () => _send(key) : null,
    icon: Icon(icon, size: 19),
    label: Text(label),
  );

  Widget _directionButton(IconData icon, int key, String label) =>
      IconButton.filledTonal(
        tooltip: label,
        onPressed: _connected ? () => _send(key) : null,
        icon: Icon(icon, size: 30),
      );

  Widget _remotePad() => Card(child: Padding(
    padding: const EdgeInsets.all(14),
    child: Column(children: [
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8,
        children: [
          _keyButton('Power', Icons.power_settings_new, KeyCode.power),
          _keyButton('Input', Icons.input, KeyCode.input),
          _keyButton('Settings', Icons.settings_outlined, KeyCode.settings),
        ]),
      const SizedBox(height: 12),
      _directionButton(Icons.keyboard_arrow_up_rounded,
          KeyCode.dpadUp, 'Up'),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _directionButton(Icons.keyboard_arrow_left_rounded,
            KeyCode.dpadLeft, 'Left'),
        const SizedBox(width: 12),
        FilledButton(
          key: const ValueKey('tcl-google-tv-ok'),
          onPressed: _connected ? () => _send(KeyCode.dpadCenter) : null,
          child: const Text('OK'),
        ),
        const SizedBox(width: 12),
        _directionButton(Icons.keyboard_arrow_right_rounded,
            KeyCode.dpadRight, 'Right'),
      ]),
      _directionButton(Icons.keyboard_arrow_down_rounded,
          KeyCode.dpadDown, 'Down'),
      const SizedBox(height: 10),
      Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8,
        children: [
          _keyButton('Back', Icons.arrow_back_rounded, KeyCode.back),
          _keyButton('Home', Icons.home_rounded, KeyCode.home),
          _keyButton('Mute', Icons.volume_off_rounded, KeyCode.volumeMute),
          _keyButton('Vol −', Icons.volume_down_rounded, KeyCode.volumeDown),
          _keyButton('Vol +', Icons.volume_up_rounded, KeyCode.volumeUp),
          _keyButton('Play/Pause', Icons.play_arrow_rounded,
              KeyCode.mediaPlayPause),
          _keyButton('Previous', Icons.skip_previous_rounded,
              KeyCode.mediaPrevious),
          _keyButton('Next', Icons.skip_next_rounded, KeyCode.mediaNext),
        ]),
    ]),
  ));

  /// Keep connection management out of the remote once a TV is connected.
  Widget _connectedRemote(TclGoogleTv? selected) => SafeArea(
    child: Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Row(children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 16),
          const SizedBox(width: 7),
          Expanded(child: Text(
            'Connected · ${selected?.name ?? 'Google TV'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          )),
        ]),
      ),
      Expanded(child: ListView(
        key: const ValueKey('tcl-google-tv-remote-view'),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
        children: [_remotePad()],
      )),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      appBar: AppBar(
        title: Text(_connected
            ? (selected?.name ?? 'TCL Google TV') : 'TCL Google TV'),
        actions: [
          if (_connected)
            IconButton(
              key: const ValueKey('tcl-google-tv-settings-toggle'),
              tooltip: _showSettings ? 'Show remote' : 'TV connection settings',
              icon: Icon(_showSettings ? Icons.settings_remote : Icons.tune),
              onPressed: () =>
                  setState(() => _showSettings = !_showSettings),
            ),
          if (_connected)
            IconButton(
              key: const ValueKey('tcl-google-tv-disconnect'),
              tooltip: 'Disconnect TV',
              icon: const Icon(Icons.link_off),
              onPressed: _disconnect,
            ),
        ],
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _connected && !_showSettings
            ? _connectedRemote(selected)
            : ListView(
                key: const ValueKey('tcl-google-tv-connection-view'),
                padding: const EdgeInsets.all(14),
                children: [
            Card(child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Google TV Remote', style: TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 18)),
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('tcl-google-tv-host'),
                    controller: _host,
                    enabled: !_working,
                    autocorrect: false,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'TV local IP',
                      hintText: '192.168.1.45',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('tcl-google-tv-name'),
                    controller: _name,
                    enabled: !_working,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(), labelText: 'TV name'),
                  ),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 7, children: [
                    OutlinedButton.icon(
                      key: const ValueKey('tcl-google-tv-save'),
                      onPressed: _working ? null : () => unawaited(_save()),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('tcl-google-tv-scan'),
                      onPressed: _working ? null : () => unawaited(_scan()),
                      icon: const Icon(Icons.radar),
                      label: const Text('Discover'),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('tcl-google-tv-pair'),
                      onPressed: _working || selected == null
                          ? null : () => unawaited(_pair()),
                      icon: const Icon(Icons.phonelink_lock_rounded),
                      label: Text(selected?.paired == true ? 'Pair again' : 'Pair'),
                    ),
                    FilledButton.icon(
                      key: const ValueKey('tcl-google-tv-connect'),
                      onPressed: _working || _connected ||
                          selected?.paired != true
                          ? null : () => unawaited(_connect()),
                      icon: const Icon(Icons.link),
                      label: const Text('Connect'),
                    ),
                    if (_connected)
                      TextButton.icon(
                        key: const ValueKey('tcl-google-tv-return-remote'),
                        onPressed: () =>
                            setState(() => _showSettings = false),
                        icon: const Icon(Icons.settings_remote),
                        label: const Text('Remote'),
                      ),
                  ]),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Text(_message!,
                        key: const ValueKey('tcl-google-tv-status'),
                        style: TextStyle(color: _ok
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.error)),
                    ),
                  if (_working) const LinearProgressIndicator(),
                  const SizedBox(height: 6),
                  Text('Pair once with the code shown on the TV. '
                       'Remote Service: control 6466 · pairing 6467. '
                       'Save does not connect, and reconnecting uses '
                       'the retained iPhone Keychain pairing.',
                       style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            )),
            if (_found.isNotEmpty) Card(child: Column(children: [
              const ListTile(title: Text('Devices accepting pairing connections')),
              for (final host in _found)
                ListTile(
                  title: Text(host),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    _disconnect();
                    _host.text = host;
                    final selectedTv = _selected;
                    _name.text = selectedTv?.name ?? 'TCL Google TV';
                    setState(() => _setResult(
                        'Selected $host. Tap Save, then Pair.'));
                  },
                ),
            ])),
            if (_saved.isNotEmpty) Card(child: Column(children: [
              const ListTile(title: Text('Saved Google TVs')),
              for (final tv in _saved)
                ListTile(
                  key: ValueKey('tcl-saved-${tv.host}'),
                  dense: true,
                  leading: const Icon(Icons.tv_rounded),
                  title: Text(tv.name),
                  subtitle: Text('${tv.host} · '
                      '${tv.paired ? "Paired" : "Not paired"}'),
                  onTap: () {
                    _disconnect();
                    _host.text = tv.host;
                    _name.text = tv.name;
                    setState(() => _setResult('Selected ${tv.name}.',
                        success: true));
                  },
                  trailing: tv.host == _host.text.trim()
                      ? IconButton(
                          tooltip: 'Remove saved TV',
                          onPressed: _working ? null
                              : () => unawaited(_remove()),
                          icon: const Icon(Icons.delete_outline),
                        )
                      : null,
                ),
            ])),
          ]),
    );
  }

  @override
  void dispose() {
    _pairing?.dispose();
    _remoteStatus?.cancel();
    _remote?.dispose();
    _host.dispose();
    _name.dispose();
    _code.dispose();
    super.dispose();
  }
}
