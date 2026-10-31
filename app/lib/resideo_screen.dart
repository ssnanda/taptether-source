import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'resideo_api.dart';
import 'resideo_oauth_screen.dart';

/// Dashboard shortcut and Settings → API Integrations share one connection,
/// but the dashboard never displays developer credentials.
class ResideoScreen extends StatefulWidget {
  const ResideoScreen({super.key, this.settingsOnly = false});
  final bool settingsOnly;

  @override
  State<ResideoScreen> createState() => _ResideoScreenState();
}

class _ResideoScreenState extends State<ResideoScreen> {
  final _api = ResideoConnection();
  final _key = TextEditingController();
  final _secret = TextEditingController();
  final _redirect = TextEditingController();
  final _authCode = TextEditingController();
  final _search = TextEditingController();
  List<ResideoDevice> _devices = [];
  Set<String> _selected = {};
  Set<String> _locations = {};
  bool _loading = true, _busy = false, _configured = false;
  bool _showSecrets = false;
  bool _manualCode = false;
  String? _pendingState;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    for (final controller in [
      _key, _secret, _redirect, _authCode, _search,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final c = await _api.credentials();
      if (!mounted) {
        return;
      }
      _key.text = c.apiKey;
      _secret.text = c.apiSecret;
      _redirect.text = c.redirectUri;
      setState(() {
        _configured = c.usable;
        _loading = false;
      });
      if (!widget.settingsOnly && c.usable) {
        await _refresh();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Cannot load Honeywell credentials from secure storage.';
          _loading = false;
        });
      }
    }
  }

  ResideoCredentials _entered() => ResideoCredentials(
    apiKey: _key.text.trim(),
    apiSecret: _secret.text.trim(),
    accessToken: '',
    refreshToken: '',
    redirectUri: _redirect.text.trim(),
  );

  String _friendly(Object error) {
    if (error is ResideoApiError) {
      return error.message;
    }
    if (error is FormatException) {
      return error.message;
    }
    return 'Honeywell request failed. Check your internet connection and credentials.';
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _error = _friendly(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  ResideoCredentials _submittedWithExisting(ResideoCredentials saved) {
    final input = _entered();
    ResideoConnection.validateRedirect(input.redirectUri);
    if (input.apiKey.isEmpty || input.apiSecret.isEmpty) {
      throw const FormatException(
          'Enter Consumer Key, Consumer Secret and Callback URL.');
    }
    final unchanged = input.apiKey == saved.apiKey &&
        input.apiSecret == saved.apiSecret &&
        input.redirectUri == saved.redirectUri;
    return ResideoCredentials(
      apiKey: input.apiKey,
      apiSecret: input.apiSecret,
      redirectUri: input.redirectUri,
      accessToken: unchanged ? saved.accessToken : '',
      refreshToken: unchanged ? saved.refreshToken : '',
      expiresAtUtc: unchanged ? saved.expiresAtUtc : null,
    );
  }

  String _newState() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  Future<void> _finishAuthorization(String code) async {
    final current = await _api.credentials();
    await _api.exchangeCode(current, code, state: _pendingState);
    _authCode.clear();
    final devices = await _api.discover();
    if (!mounted) return;
    setState(() {
      _configured = true;
      _manualCode = false;
      _pendingState = null;
      _notice = 'Resideo connected · ${devices.length} thermostats found';
    });
  }

  Future<void> _authorize() => _run(() async {
    final current = await _api.credentials();
    final submitted = _submittedWithExisting(current);
    await _api.save(submitted);
    _pendingState = _newState();
    final authorization = ResideoConnection.authorizationUrl(
      submitted.apiKey, submitted.redirectUri, state: _pendingState);
    if (!mounted) return;
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => ResideoOAuthScreen(
        authorizationUrl: authorization,
        callbackUrl: submitted.redirectUri,
        state: _pendingState!,
      )));
    if (!mounted) return;
    if (code == null) {
      setState(() {
        _manualCode = true;
        _notice = 'If you used Safari, paste the redirect URL or code below.';
      });
      return;
    }
    await _finishAuthorization(code);
  });

  Future<void> _exchange() => _run(() async {
    if (_authCode.text.trim().isEmpty) {
      throw const FormatException('Paste the returned authorization code.');
    }
    await _finishAuthorization(_authCode.text.trim());
  });

  Future<void> _disconnect() => _run(() async {
    await _api.disconnect();
    if (!mounted) {
      return;
    }
    _secret.clear();
    _authCode.clear();
    setState(() {
      _configured = false;
      _devices = [];
      _selected = {};
      _notice = 'Honeywell connection removed from this device.';
    });
  });

  Future<void> _load() async {
    final devices = await _api.discover();
    if (!mounted) {
      return;
    }
    setState(() {
      _devices = devices;
      final ids = devices.map((d) => d.id).toSet();
      if (_selected.isEmpty) {
        _selected = ids;
      }
      _selected = _selected.intersection(ids);
      final locations = devices.map((d) => d.locationId).toSet();
      if (_locations.isEmpty) {
        _locations = locations;
      }
      _locations = _locations.intersection(locations);
    });
  }

  Future<void> _refresh() => _run(_load);

  Future<void> _change(ResideoDevice device, String mode,
      {bool fan = false, double? heat, double? cool}) async {
    await _api.mode(device, mode, fan: fan, heat: heat, cool: cool);
    await _load();
  }

  Future<void> _bulk(String mode, {required bool fan}) => _run(() async {
    final list = _devices.where((d) =>
        _selected.contains(d.id) && _locations.contains(d.locationId)).toList();
    if (list.isEmpty) {
      return;
    }
    var changed = 0;
    final failures = <String>[];
    for (final device in list) {
      final supported = fan ? device.supportsFan(mode)
          : device.systemModes.any((m) => m.toLowerCase() == mode.toLowerCase());
      if (!supported) {
        failures.add('${device.name}: unsupported mode');
        continue;
      }
      try {
        await _api.mode(device, mode, fan: fan);
        changed++;
      } catch (_) {
        failures.add('${device.name}: failed');
      }
    }
    await _load();
    if (!mounted) {
      return;
    }
    setState(() {
      _notice = 'Updated $changed of ${list.length} thermostats.';
      if (failures.isNotEmpty) {
        _error = failures.join(' · ');
      }
    });
  });

  Widget _modeChoices(String heading, List<String> modes, String? selected,
      void Function(String) change) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(heading, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 7),
      Wrap(spacing: 7, runSpacing: 4, children: [
        for (final mode in modes)
          ChoiceChip(
            label: Text(mode),
            selected: mode.toLowerCase() == selected?.toLowerCase(),
            onSelected: _busy ? null : (_) => change(mode),
          ),
      ]),
    ],
  );

  void _details(ResideoDevice original) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (ctx, redraw) {
          final device = _devices.where((d) => d.id == original.id)
              .firstOrNull ?? original;
          Future<void> update(Future<void> Function() action) async {
            if (_busy) {
              return;
            }
            await _run(action);
            if (ctx.mounted) {
              redraw(() {});
            }
          }
          Widget setpoint(String label, double? value, bool heating) {
            return Row(children: [
              Expanded(child: Text('$label: ${device.display(value)}')),
              IconButton(
                tooltip: 'Decrease $label',
                onPressed: _busy || !device.online || value == null ? null
                    : () => update(() async {
                        final next = device.adjustedSetpoint(
                            heating: heating, direction: -1);
                        await _change(device, device.system,
                            heat: heating ? next : null,
                            cool: heating ? null : next);
                      }),
                icon: const Icon(Icons.remove_circle_outline),
              ),
              IconButton(
                tooltip: 'Increase $label',
                onPressed: _busy || !device.online || value == null ? null
                    : () => update(() async {
                        final next = device.adjustedSetpoint(
                            heating: heating, direction: 1);
                        await _change(device, device.system,
                            heat: heating ? next : null,
                            cool: heating ? null : next);
                      }),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ]);
          }

          return SafeArea(child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20, 6, 20, MediaQuery.viewInsetsOf(ctx).bottom + 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.name, style: Theme.of(ctx).textTheme.titleLarge),
                Text('${device.location} · ${device.online ? 'Online' : 'Offline'}',
                    style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 12),
                Text('Indoor ${device.display(device.temperature)}',
                    style: Theme.of(ctx).textTheme.headlineSmall),
                const SizedBox(height: 12),
                if (!device.online)
                  const Text('This thermostat is offline. Controls are disabled.'),
                setpoint('Heat', device.heat, true),
                setpoint('Cool', device.cool, false),
                const SizedBox(height: 16),
                _modeChoices('System', device.systemModes, device.system,
                    (mode) => update(
                        () => _change(device, mode))),
                const SizedBox(height: 12),
                _modeChoices('Fan', device.fanModes, device.fan,
                    (mode) => update(
                        () => _change(device, mode, fan: true))),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Text(_error!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ],
            ),
          ));
        },
      ),
    );
  }

  Widget _settings() {
    InputDecoration field(String label) => InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
    );
    Widget entry(TextEditingController controller, String label,
        {bool secret = false}) => TextField(
      controller: controller,
      obscureText: secret && !_showSecrets,
      autocorrect: false,
      enableSuggestions: !secret,
      decoration: field(label),
    );

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Resideo / Honeywell Home',
          style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 6),
      const Text('Enter the three values from your approved app at '
          'developer.honeywellhome.com. TapTether handles the OAuth tokens.'),
      const SizedBox(height: 18),
      entry(_key, 'Consumer Key'),
      const SizedBox(height: 12),
      entry(_secret, 'Consumer Secret', secret: true),
      const SizedBox(height: 12),
      entry(_redirect, 'Callback URL'),
      const SizedBox(height: 6),
      Align(alignment: Alignment.centerRight,
        child: TextButton.icon(
          key: const ValueKey('resideo-reveal-secrets'),
          onPressed: () => setState(() => _showSecrets = !_showSecrets),
          icon: Icon(_showSecrets ? Icons.visibility_off : Icons.visibility),
          label: Text(_showSecrets ? 'Hide Consumer Secret' : 'Show Consumer Secret'),
        ),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        key: const ValueKey('resideo-authorize'),
        onPressed: _busy ? null : _authorize,
        icon: const Icon(Icons.login_rounded),
        label: Text(_configured ? 'Reconnect with Resideo' : 'Sign in to Resideo'),
      ),
      const SizedBox(height: 10),
      const Text('1. Sign in on the Resideo website and approve TapTether. '
          '2. TapTether captures the authorization code and exchanges it '
          'for access and refresh tokens automatically.'),
      if (_manualCode) ...[
        const SizedBox(height: 20),
        const Divider(),
        Text('Finish Safari sign-in',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        const Text('If Safari reports that localhost cannot be reached, '
            'copy the redirect address from the browser. '
            'Paste the full address or its code below.'),
        const SizedBox(height: 10),
        entry(_authCode, 'Redirect URL or authorization code'),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('resideo-exchange-code'),
          onPressed: _busy ? null : _exchange,
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Complete connection'),
        ),
      ],
      const SizedBox(height: 14),
      const Text('Consumer credentials and tokens stay encrypted on this '
          'device, not in cloud backups. Tokens renew while TapTether is in use.'),
      if (_configured) ...[
        const SizedBox(height: 18),
        ListTile(
          leading: const Icon(Icons.check_circle_outline, color: Colors.green),
          title: const Text('Resideo connected'),
          subtitle: const Text('Tokens are managed automatically on this phone.'),
          contentPadding: EdgeInsets.zero,
        ),
        OutlinedButton.icon(
          key: const ValueKey('resideo-api-disconnect'),
          onPressed: _busy ? null : _disconnect,
          icon: const Icon(Icons.link_off),
          label: const Text('Disconnect Resideo'),
        ),
      ],
      if (_busy) const LinearProgressIndicator(),
    ]);
  }

  Widget _dashboard() {
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    final visible = _devices.where((d) =>
        _locations.contains(d.locationId) &&
        (query.isEmpty || d.name.toLowerCase().contains(query) ||
         d.location.toLowerCase().contains(query))).toList();
    final selected = visible.where((d) => _selected.contains(d.id)).toList();
    final locations = <String, String>{
      for (final d in _devices)
        d.locationId: d.location.isEmpty ? d.locationId : d.location,
    };
    return ListView(padding: const EdgeInsets.all(14), children: [
      if (!_configured) ...[
        const ListTile(
          leading: Icon(Icons.thermostat_outlined),
          title: Text('Connect Honeywell Home'),
          subtitle: Text('Set your API key and OAuth token in API Integrations.'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Open Resideo API settings'),
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const ResideoScreen(settingsOnly: true)));
            if (mounted) {
              await _restore();
            }
          },
        ),
      ] else ...[
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'Search thermostats',
            prefixIcon: Icon(Icons.search_rounded),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (locations.length > 1) Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(spacing: 6, children: [
            for (final entry in locations.entries)
              FilterChip(
                label: Text(entry.value),
                selected: _locations.contains(entry.key),
                onSelected: (_) => setState(() {
                  if (!_locations.add(entry.key)) {
                    _locations.remove(entry.key);
                  }
                }),
              ),
          ]),
        ),
        if (_devices.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            Text('${selected.length} selected',
                style: theme.textTheme.labelLarge),
            const Spacer(),
            TextButton(
              onPressed: () => setState(
                () => _selected = _devices.map((d) => d.id).toSet()),
              child: const Text('All'),
            ),
            TextButton(
              onPressed: () => setState(() => _selected.clear()),
              child: const Text('None'),
            ),
          ]),
          _modeChoices('System · Selected',
            const ['Off', 'Cool', 'Heat', 'Auto'],
            null, (m) => _bulk(m, fan: false)),
          const SizedBox(height: 9),
          _modeChoices('Fan · Selected',
            const ['On', 'Auto', 'Circulate'],
            null, (m) => _bulk(m, fan: true)),
          const SizedBox(height: 16),
        ],
        for (final d in visible) Card(
          child: ListTile(
            dense: true,
            leading: Checkbox(
              value: _selected.contains(d.id),
              onChanged: (_) => setState(() {
                if (!_selected.add(d.id)) {
                  _selected.remove(d.id);
                }
              }),
            ),
            title: Text(d.name, maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: Text('${d.location} · ${d.system} · Fan ${d.fan}',
                maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(d.display(d.temperature),
                    style: theme.textTheme.titleMedium),
                Text(d.online ? 'Online' : 'Offline',
                    style: theme.textTheme.labelSmall),
              ],
            ),
            onTap: () => _details(d),
          ),
        ),
        if (_devices.isEmpty && !_busy)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('No Honeywell Home thermostats found.')),
          ),
      ],
      if (_busy) const LinearProgressIndicator(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.settingsOnly ? 'Resideo API' : 'Thermostats'),
        actions: [
          if (!widget.settingsOnly && _configured)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Refresh thermostats',
              onPressed: _busy ? null : _refresh,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (_error != null) Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    const Icon(Icons.error_outline),
                    const SizedBox(width: 9),
                    Expanded(child: Text(_error!)),
                  ]),
                ),
              ),
              if (_notice != null) Padding(
                padding: const EdgeInsets.all(10),
                child: Text(_notice!),
              ),
              Expanded(child: widget.settingsOnly ? _settings() : _dashboard()),
            ]),
    );
  }
}
