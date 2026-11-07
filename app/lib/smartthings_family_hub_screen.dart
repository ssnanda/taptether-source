import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'display_time.dart';
import 'smartthings_family_hub.dart';

/// Samsung Family Hub: known LAN IP + read-only SmartThings sensor status.
/// Save remains offline and never tests credentials or replaces saved tokens.
class SmartThingsFamilyHubScreen extends StatefulWidget {
  const SmartThingsFamilyHubScreen({
    super.key, this.initialIp, this.onSaved, this.store, this.client,
  });
  final String? initialIp;
  final Future<void> Function()? onSaved;
  final FamilyHubStore? store;
  final FamilyHubClient? client;

  @override
  State<SmartThingsFamilyHubScreen> createState() =>
      _SmartThingsFamilyHubScreenState();
}

class _SmartThingsFamilyHubScreenState
    extends State<SmartThingsFamilyHubScreen> {
  late final FamilyHubStore _store = widget.store ?? FamilyHubStore();
  late final FamilyHubClient _client = widget.client ??
      FamilyHubClient(store: _store);
  final _ip = TextEditingController();
  final _pat = TextEditingController();
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  final _redirect = TextEditingController();
  final _callback = TextEditingController();
  FamilyHubSettings _settings = const FamilyHubSettings();
  List<FamilyHubDevice> _devices = [];
  FamilyHubStatus? _status;
  bool _busy = true;
  bool? _localReachable;
  String? _message;
  bool _ok = false;
  DateTime? _checked;
  String? _state;

  @override
  void initState() {
    super.initState();
    _ip.text = widget.initialIp ?? '';
    unawaited(_restore());
  }

  Future<void> _restore() async {
    try {
      final config = await _store.read();
      if (!mounted) {
        return;
      }
      setState(() {
        _settings = config;
        _ip.text = widget.initialIp ?? config.localIp;
        _clientId.text = config.clientId;
        _redirect.text = config.redirectUri;
        _busy = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _show('Saved Family Hub configuration could not be read.');
        });
      }
    }
  }

  void _show(String message, {bool good = false}) {
    _message = message;
    _ok = good;
  }

  FamilyHubSettings _entered() {
    final ip = _ip.text.trim();
    if (ip.isEmpty) {
      throw const FormatException('Enter the Samsung Family Hub local IP.');
    }
    final previous = _settings;
    return previous.copyWith(
      localIp: ip,
      personalToken: _pat.text.trim().isNotEmpty
          ? _pat.text.trim() : previous.personalToken,
      clientId: _clientId.text.trim(),
      clientSecret: _clientSecret.text.isNotEmpty
          ? _clientSecret.text : previous.clientSecret,
      redirectUri: _redirect.text.trim(),
    );
  }

  Future<void> _save() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final config = _entered();
      await _store.save(config);
      if (!mounted) {
        return;
      }
      _pat.clear();
      _clientSecret.clear();
      setState(() {
        _settings = config;
        _localReachable = null;
        _show('Saved to iPhone Keychain. Connect when ready.', good: true);
      });
      await widget.onSaved?.call();
    } on FormatException catch (e) {
      if (mounted) {
        setState(() => _show(e.message));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _show('Could not save Family Hub configuration.'));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _checkLocal() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await familyHubPortReachable(_ip.text.trim());
      if (!mounted) {
        return;
      }
      setState(() {
        _localReachable = result;
        _show(result
          ? 'TCP 17654 is reachable. This is a Family Hub hint, '
              'not an authenticated local-control connection.'
          : 'Port 17654 did not respond. Verify this phone is on the '
              'same Wi-Fi; closed ports do not prove the fridge is offline.',
          good: result);
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _connect() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      // Explicit Connect uses saved credentials only; never overwrites them.
      final saved = await _store.read();
      if (!saved.connected) {
        throw const FamilyHubApiException(
            'Save a SmartThings token or complete OAuth sign-in first.');
      }
      final devices = await _client.refrigerators();
      if (!mounted) {
        return;
      }
      final preferred = devices.where((x) =>
          x.id == saved.deviceId).toList();
      final selected = preferred.isNotEmpty
          ? preferred.first : devices.firstOrNull;
      FamilyHubStatus? status;
      if (selected != null) {
        status = await _client.status(selected.id);
        if (selected.id != saved.deviceId) {
          final updated = saved.copyWith(deviceId: selected.id);
          await _store.save(updated);
          _settings = updated;
          await widget.onSaved?.call();
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = devices;
        _status = status;
        _checked = DateTime.now();
        _show(selected == null
            ? 'Connected to SmartThings, but no refrigerator was reported.'
            : 'Connected to SmartThings · ' + selected.name,
          good: true);
      });
    } on FamilyHubApiException catch (e) {
      if (mounted) {
        setState(() => _show(e.message));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _show('Could not load Samsung SmartThings devices.'));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _select(FamilyHubDevice selected) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final status = await _client.status(selected.id);
      final config = (await _store.read()).copyWith(deviceId: selected.id);
      await _store.save(config);
      if (!mounted) {
        return;
      }
      setState(() {
        _settings = config;
        _status = status;
        _checked = DateTime.now();
        _show('Connected to ' + selected.name, good: true);
      });
      await widget.onSaved?.call();
    } catch (_) {
      if (mounted) {
        setState(() => _show('Could not read refrigerator status.'));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _startOAuth() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      // Explicitly save first, without losing the user-entered credentials.
      final config = _entered();
      if (!config.oauthReady) {
        throw const FormatException(
            'Enter Client ID, Client Secret and registered Redirect URL.');
      }
      await _store.save(config);
      _settings = config;
      final state = FamilyHubClient.newState();
      final url = FamilyHubClient.authorizeUrl(config, state);
      _state = state;
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const FormatException(
            'Could not open SmartThings sign-in browser.');
      }
      if (!mounted) {
        return;
      }
      setState(() => _show(
          'Authorize in the browser, then paste the full callback URL below.',
          good: true));
      await widget.onSaved?.call();
    } on FormatException catch (e) {
      if (mounted) {
        setState(() => _show(e.message));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _show(
            'Cannot start SmartThings OAuth authorization.'));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _finishOAuth() async {
    if (_busy || _state == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final config = await _store.read();
      final code = FamilyHubClient.codeFromCallback(
          _callback.text.trim(), config.redirectUri, _state!);
      await _client.exchangeCode(config, code);
      _state = null;
      _callback.clear();
      if (!mounted) {
        return;
      }
      setState(() => _show(
          'SmartThings OAuth connected and saved, with token refresh.',
          good: true));
      await widget.onSaved?.call();
    } on FormatException catch (e) {
      if (mounted) {
        setState(() => _show(e.message));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _show(
            'SmartThings OAuth exchange failed. Verify the callback URL.'));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Widget _entry(TextEditingController control, String label,
      {String? hint, bool secret = false, Key? fieldKey}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          key: fieldKey,
          controller: control,
          enabled: !_busy,
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: !secret,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: label, hintText: hint),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final selected = _devices.where((x) =>
        x.id == _settings.deviceId).firstOrNull;
    final readings = _status?.readings() ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('Samsung Family Hub')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        Card(child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Refrigerator · Wi-Fi',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 9),
              _entry(_ip, 'Local IP address',
                  hint: '192.168.1.88',
                  fieldKey: const ValueKey('family-hub-ip')),
              OutlinedButton.icon(
                key: const ValueKey('family-hub-test-local'),
                onPressed: _busy ? null : () => unawaited(_checkLocal()),
                icon: const Icon(Icons.wifi_find),
                label: const Text('Check local service'),
              ),
              if (_localReachable == true)
                const Text('TCP 17654 reachable · identity unverified'),
              const SizedBox(height: 10),
              Text('Refrigerator data uses Samsung SmartThings. '
                  'The Family Hub touchscreen is not a TV remote.',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        )),
        Card(child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('SmartThings connection',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 7),
              _entry(_pat, 'SmartThings personal access token',
                  hint: _settings.personalToken.isNotEmpty
                      ? 'Saved · leave blank to retain' : 'Paste token',
                  secret: true, fieldKey: const ValueKey('family-hub-token')),
              Text('Personal tokens generally expire after 24 hours. '
                  'For a permanent connection, use OAuth below.',
                  style: Theme.of(context).textTheme.bodySmall),
              Align(alignment: Alignment.centerLeft, child: TextButton.icon(
                onPressed: () => unawaited(launchUrl(
                  Uri.parse('https://account.smartthings.com/tokens'),
                  mode: LaunchMode.externalApplication)),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Get a SmartThings test token'),
              )),
              Wrap(spacing: 10, runSpacing: 8, children: [
                OutlinedButton.icon(
                  key: const ValueKey('family-hub-save'),
                  onPressed: _busy ? null : () => unawaited(_save()),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save'),
                ),
                FilledButton.icon(
                  key: const ValueKey('family-hub-connect'),
                  onPressed: _busy || !_settings.connected
                      ? null : () => unawaited(_connect()),
                  icon: const Icon(Icons.link),
                  label: const Text('Connect'),
                ),
              ]),
              ExpansionTile(
                key: const ValueKey('family-hub-oauth-settings'),
                title: const Text('Permanent OAuth connection'),
                tilePadding: EdgeInsets.zero,
                children: [
                  _entry(_clientId, 'Client ID'),
                  _entry(_clientSecret, 'Client Secret',
                      hint: _settings.clientSecret.isNotEmpty
                          ? 'Saved · leave blank to retain' : null,
                      secret: true),
                  _entry(_redirect, 'Registered HTTPS redirect URL'),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => unawaited(_startOAuth()),
                    icon: const Icon(Icons.login),
                    label: const Text('Authorize with Samsung'),
                  ),
                  if (_state != null) ...[
                    _entry(_callback, 'Full OAuth callback URL',
                        fieldKey: const ValueKey('family-hub-callback')),
                    FilledButton(
                      onPressed: _busy ? null
                          : () => unawaited(_finishOAuth()),
                      child: const Text('Complete sign-in'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        )),
        if (_busy) const LinearProgressIndicator(),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(_message!,
              key: const ValueKey('family-hub-message'),
              style: TextStyle(color: _ok
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error)),
          ),
        if (_devices.isNotEmpty) Card(
          child: Column(children: [
            const ListTile(title: Text('SmartThings refrigerators')),
            for (final device in _devices)
              ListTile(
                title: Text(device.name),
                subtitle: Text(device.model),
                trailing: Icon(device.id == _settings.deviceId
                    ? Icons.check_circle : Icons.chevron_right),
                onTap: _busy ? null : () => unawaited(_select(device)),
              ),
          ]),
        ),
        if (selected != null) Card(child: Column(children: [
          ListTile(title: Text(selected.name),
            subtitle: Text(_checked == null ? 'Not refreshed'
              : 'Updated ' + displayTimeAmPm(_checked!)),
            trailing: IconButton(
              tooltip: 'Refresh status',
              onPressed: _busy ? null : () => unawaited(_connect()),
              icon: const Icon(Icons.refresh),
            ),
          ),
          if (readings.isEmpty)
            const ListTile(title: Text('No exposed refrigerator readings'),
              subtitle: Text('SmartThings has not reported temperature, '
                  'door or setpoint capabilities for this device.')),
          for (final entry in readings)
            ListTile(
              dense: true,
              title: Text(entry.label),
              trailing: Text(entry.value),
            ),
        ])),
        const SizedBox(height: 12),
        Text('Read-only integration. Local TCP 17654 is not an '
            'authenticated Family Hub screen-control API. '
            'No touchscreen, app launching or media remote is available.',
          style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }

  @override
  void dispose() {
    _ip.dispose();
    _pat.dispose();
    _clientId.dispose();
    _clientSecret.dispose();
    _redirect.dispose();
    _callback.dispose();
    super.dispose();
  }
}
