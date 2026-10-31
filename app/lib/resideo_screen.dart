import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'resideo_api.dart';

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
  final _access = TextEditingController();
  final _refreshToken = TextEditingController();
  final _redirect = TextEditingController();
  final _authCode = TextEditingController();
  final _search = TextEditingController();
  List<ResideoDevice> _devices = [];
  Set<String> _selected = {};
  Set<String> _locations = {};
  bool _loading = true, _busy = false, _configured = false;
  bool _showSecrets = false;
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
      _key, _secret, _access, _refreshToken, _redirect, _authCode, _search,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final c = await _api.credentials();
      if (!mounted) return;
      _key.text = c.apiKey;
      _secret.text = c.apiSecret;
      _access.text = c.accessToken;
      _refreshToken.text = c.refreshToken;
      _redirect.text = c.redirectUri;
      setState(() {
        _configured = c.usable;
        _loading = false;
      });
      if (!widget.settingsOnly && c.usable) await _refresh();
    } catch (_) {
      if (mounted) setState(() {
        _error = 'Cannot load Honeywell credentials from secure storage.';
        _loading = false;
      });
    }
  }

  ResideoCredentials _entered() => ResideoCredentials(
    apiKey: _key.text.trim(),
    apiSecret: _secret.text.trim(),
    accessToken: _access.text.trim(),
    refreshToken: _refreshToken.text.trim(),
    redirectUri: _redirect.text.trim(),
  );

  String _friendly(Object error) {
    if (error is ResideoApiError) return error.message;
    if (error is FormatException) return error.message;
    return 'Honeywell request failed. Check your internet connection and credentials.';
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _friendly(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run(() async {
    final c = _entered();
    if (c.accessToken.isEmpty && (c.apiSecret.isEmpty ||
        c.refreshToken.isEmpty)) {
      throw const FormatException(
        'Supply an access token, or a client secret and refresh token.');
    }
    await _api.save(c);
    if (mounted) {
      setState(() {
        _configured = true;
        _notice = 'Honeywell credentials saved securely.';
      });
    }
    // Verify against the real Honeywell locations endpoint.
    final devices = await _api.discover();
    if (!mounted) return;
    setState(() => _notice =
        'Honeywell connected. Found ${devices.length} thermostat(s).');
    // A refresh may rotate the token. Reflect the newest secured credentials.
    await _reloadTokenFields();
  });

  Future<void> _reloadTokenFields() async {
    final current = await _api.credentials();
    if (!mounted) return;
    _access.text = current.accessToken;
    _refreshToken.text = current.refreshToken;
    setState(() => _configured = current.usable);
  }

  Future<void> _authorize() => _run(() async {
    final url = ResideoConnection.authorizationUrl(
      _key.text, _redirect.text);
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened) {
      throw const ResideoApiError('Unable to open Honeywell authorization.');
    }
    if (mounted) {
      setState(() => _notice =
          'Authorize in your browser, then paste the returned code or redirect URL below.');
    }
  });

  Future<void> _exchange() => _run(() async {
    await _api.exchangeCode(_entered(), _authCode.text);
    _authCode.clear();
    await _reloadTokenFields();
    final devices = await _api.discover();
    if (mounted) {
      setState(() => _notice =
          'Authorized directly with Honeywell. Found ${devices.length} thermostat(s).');
    }
  });

  Future<void> _disconnect() => _run(() async {
    await _api.disconnect();
    if (!mounted) return;
    _secret.clear();
    _access.clear();
    _refreshToken.clear();
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
    if (!mounted) return;
    setState(() {
      _devices = devices;
      final ids = devices.map((d) => d.id).toSet();
      if (_selected.isEmpty) _selected = ids;
      _selected = _selected.intersection(ids);
      final locations = devices.map((d) => d.locationId).toSet();
      if (_locations.isEmpty) _locations = locations;
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
    if (list.isEmpty) return;
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
    if (!mounted) return;
    setState(() {
      _notice = 'Updated $changed of ${list.length} thermostats.';
      if (failures.isNotEmpty) _error = failures.join(' · ');
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
            if (_busy) return;
            await _run(action);
            if (ctx.mounted) redraw(() {});
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
      Text('Honeywell Home Developer API',
          style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 7),
      const Text('Connect directly to api.honeywellhome.com. No AJCore or AJOps account is required.'),
      const SizedBox(height: 16),
      entry(_key, 'API Key / Client ID'),
      const SizedBox(height: 12),
      entry(_secret, 'API Secret / Client Secret', secret: true),
      const SizedBox(height: 12),
      entry(_access, 'OAuth Access Token', secret: true),
      const SizedBox(height: 12),
      entry(_refreshToken, 'OAuth Refresh Token (optional)', secret: true),
      const SizedBox(height: 6),
      Align(alignment: Alignment.centerRight,
        child: TextButton.icon(
          key: const ValueKey('resideo-reveal-secrets'),
          onPressed: () => setState(() => _showSecrets = !_showSecrets),
          icon: Icon(_showSecrets ? Icons.visibility_off : Icons.visibility),
          label: Text(_showSecrets ? 'Hide credentials' : 'Show credentials'),
        )),
      FilledButton.icon(
        key: const ValueKey('resideo-save-api-credentials'),
        onPressed: _busy ? null : _save,
        icon: const Icon(Icons.lock_outline),
        label: const Text('Save & Connect'),
      ),
      const SizedBox(height: 6),
      const Text('Saved in device secure storage. Tokens renew automatically when you provide a refresh token and API secret.'),
      const SizedBox(height: 18),
      const Divider(),
      ExpansionTile(
        title: const Text('Get a new OAuth token'),
        subtitle: const Text('Authorize your Honeywell Home account in a browser'),
        children: [
          const SizedBox(height: 6),
          entry(_redirect, 'Registered OAuth redirect URL'),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _authorize,
            icon: const Icon(Icons.open_in_browser),
            label: const Text('Open Honeywell authorization'),
          ),
          const SizedBox(height: 8),
          entry(_authCode, 'Authorization code or returned redirect URL'),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            key: const ValueKey('resideo-exchange-code'),
            onPressed: _busy ? null : _exchange,
            icon: const Icon(Icons.vpn_key_outlined),
            label: const Text('Exchange code for token'),
          ),
          const SizedBox(height: 12),
          const Text('Use the same redirect URL you registered at developer.honeywellhome.com. Copy the code from the browser redirect and paste it here.'),
        ],
      ),
      if (_configured) ...[
        const SizedBox(height: 16),
        OutlinedButton.icon(
          key: const ValueKey('resideo-api-disconnect'),
          onPressed: _busy ? null : _disconnect,
          icon: const Icon(Icons.link_off),
          label: const Text('Disconnect Honeywell Home'),
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
            if (mounted) await _restore();
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
                  if (!_locations.add(entry.key)) _locations.remove(entry.key);
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
                if (!_selected.add(d.id)) _selected.remove(d.id);
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
