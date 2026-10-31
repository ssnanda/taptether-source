import 'dart:async';
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
  bool _bulkMode = false;
  DateTime? _lastChecked;
  final Map<String, Timer> _targetTimers = {};
  final Map<String, ResideoDevice> _targetOriginals = {};
  final Set<String> _sendingTargets = {};
  bool _manualCode = false;
  String? _pendingState;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    final memory = ResideoConnection.memoryDevices;
    if (memory != null && !widget.settingsOnly) {
      _devices = memory;
      _lastChecked = ResideoConnection.memoryTimestamp;
      _locations = memory.map((d) => d.locationId).toSet();
      _configured = true;
      _loading = false;
    }
    _restore();
  }

  @override
  void dispose() {
    for (final timer in _targetTimers.values) {
      timer.cancel();
    }
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
      if (c.usable && !widget.settingsOnly && _devices.isEmpty) {
        final (cached, checkedAt) = await _api.cachedDevices();
        if (!mounted) return;
        if (cached.isNotEmpty) {
          setState(() {
            _devices = cached;
            _lastChecked = checkedAt;
            _locations = cached.map((d) => d.locationId).toSet();
            _loading = false;
          });
        }
      }
      setState(() {
        _configured = c.usable;
        _loading = false;
      });
      if (!widget.settingsOnly && c.usable) {
        // Previously saved values show while the remote API refreshes.
        _refresh();
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
    if (!mounted) {
      return;
    }
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
    if (!mounted) {
      return;
    }
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => ResideoOAuthScreen(
        authorizationUrl: authorization,
        callbackUrl: submitted.redirectUri,
        state: _pendingState!,
      )));
    if (!mounted) {
      return;
    }
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
      _bulkMode = false;
      _lastChecked = null;
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
      // Bulk selection must always be a deliberate user action.
      _selected = _selected.intersection(ids);
      _lastChecked = DateTime.now();
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

  /// Changes are shown immediately and short taps are coalesced into
  /// one Resideo API command, rather than a five-second full scan per tap.
  void _adjustTarget(ResideoDevice tapped, bool heating, int direction) {
    final key = tapped.cacheId;
    if (_sendingTargets.contains(key)) return;
    final current = _devices.where((d) => d.cacheId == key)
        .firstOrNull ?? tapped;
    try {
      final newTarget = current.adjustedSetpoint(
          heating: heating, direction: direction);
      _targetOriginals.putIfAbsent(key, () => tapped);
      final updated = current.withTarget(
        heatTarget: heating ? newTarget : null,
        coolTarget: heating ? null : newTarget,
      );
      setState(() {
        _error = null;
        _devices = [
          for (final d in _devices) if (d.cacheId == key) updated else d,
        ];
      });
      _targetTimers.remove(key)?.cancel();
      _targetTimers[key] = Timer(const Duration(milliseconds: 550),
          () => _commitTarget(key));
    } catch (error) {
      setState(() => _error = _friendly(error));
    }
  }

  Future<void> _commitTarget(String key) async {
    _targetTimers.remove(key);
    final current = _devices.where((d) => d.cacheId == key).firstOrNull;
    if (current == null || _sendingTargets.contains(key)) return;
    setState(() => _sendingTargets.add(key));
    try {
      await _api.mode(current, current.system,
          heat: current.heat, cool: current.cool);
      // Preserve the confirmed optimistic value across immediate reopen.
      await _api.rememberUpdated(current);
      _targetOriginals.remove(key);
    } catch (error) {
      final previous = _targetOriginals.remove(key);
      if (mounted) {
        setState(() {
          _error = _friendly(error);
          if (previous != null) {
            _devices = [
              for (final d in _devices)
                if (d.cacheId == key) previous else d,
            ];
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() => _sendingTargets.remove(key));
      }
    }
  }

  Widget _temperatureControls(ResideoDevice d, bool heating) {
    final value = heating ? d.heat : d.cool;
    if (value == null || !d.online) return const SizedBox.shrink();
    final sending = _sendingTargets.contains(d.cacheId);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton.filledTonal(
        key: ValueKey('resideo-decrease-${d.cacheId}-${heating ? 'heat' : 'cool'}'),
        tooltip: 'Lower ${d.name} ${heating ? 'heat' : 'cool'} target',
        icon: const Icon(Icons.remove_rounded),
        onPressed: sending ? null : () => _adjustTarget(d, heating, -1),
      ),
      const SizedBox(width: 2),
      IconButton.filledTonal(
        key: ValueKey('resideo-increase-${d.cacheId}-${heating ? 'heat' : 'cool'}'),
        tooltip: 'Raise ${d.name} ${heating ? 'heat' : 'cool'} target',
        icon: const Icon(Icons.add_rounded),
        onPressed: sending ? null : () => _adjustTarget(d, heating, 1),
      ),
    ]);
  }

  Future<void> _bulk(String mode, {required bool fan}) async {
    final chosen = _devices.where((d) =>
        _selected.contains(d.id) && _locations.contains(d.locationId) &&
        d.online).toList();
    if (chosen.isEmpty || _busy) return;
    final kind = fan ? 'fan' : 'system';
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Confirm multiple thermostats'),
        content: Text('Set $kind mode to $mode on ${chosen.length} '
            'selected thermostat${chosen.length == 1 ? '' : 's'}? '
            'This changes real equipment.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Apply changes')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    await _run(() async {
      var changed = 0;
      final failures = <String>[];
      for (final device in chosen) {
        final supported = fan ? device.supportsFan(mode)
            : device.systemModes.any(
                (m) => m.toLowerCase() == mode.toLowerCase());
        if (!supported) {
          failures.add('${device.name}: mode unavailable');
          continue;
        }
        try {
          await _api.mode(device, mode, fan: fan);
          changed++;
        } catch (_) {
          failures.add('${device.name}: not updated');
        }
      }
      await _load();
      if (!mounted) return;
      setState(() {
        _notice = 'Updated $changed of ${chosen.length} thermostats.';
        if (failures.isNotEmpty) _error = failures.join(' · ');
      });
    });
  }

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
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (ctx, redraw) {
          final d = _devices.where((item) => item.cacheId == original.cacheId)
              .firstOrNull ?? original;
          final scheme = Theme.of(ctx).colorScheme;

          Future<void> apply(Future<void> Function() operation) async {
            if (_busy) return;
            await _run(operation);
            if (ctx.mounted) redraw(() {});
          }

          Widget adjustment(bool heating) {
            final value = heating ? d.heat : d.cool;
            final label = heating ? 'Heat to' : 'Cool to';
            return Card(
              color: scheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                child: Row(children: [
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: Theme.of(ctx).textTheme.labelMedium),
                      Text(d.display(value),
                          style: Theme.of(ctx).textTheme.headlineSmall),
                    ],
                  )),
                  _temperatureControls(d, heating),
                ]),
              ),
            );
          }

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                18, 8, 18, MediaQuery.viewInsetsOf(ctx).bottom + 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name, style: Theme.of(ctx).textTheme.headlineSmall),
                      Text(d.location, style: Theme.of(ctx).textTheme.bodySmall),
                    ],
                  )),
                  Chip(label: Text(d.online ? 'Online' : 'Offline')),
                ]),
                const SizedBox(height: 14),
                Center(child: Column(children: [
                  Text('ROOM TEMPERATURE',
                    style: Theme.of(ctx).textTheme.labelMedium),
                  Text(d.display(d.temperature),
                    style: Theme.of(ctx).textTheme.displayMedium),
                  const SizedBox(height: 4),
                  Text('System mode: ${d.modeLabel}',
                    style: Theme.of(ctx).textTheme.bodyMedium),
                ])),
                const SizedBox(height: 20),
                if (d.isCoolMode) adjustment(false),
                if (d.isHeatMode) adjustment(true),
                if (d.isAutoMode) ...[
                  const Text('Auto mode uses two targets',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  adjustment(true),
                  adjustment(false),
                ],
                if (d.isOffMode)
                  const ListTile(
                    leading: Icon(Icons.power_settings_new),
                    title: Text('System is off'),
                    subtitle: Text('No active temperature target'),
                  ),
                if (!d.online)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('Offline: changes are unavailable.'),
                  ),
                const SizedBox(height: 16),
                _modeChoices('System mode', d.systemModes, d.system,
                  (mode) => apply(() => _change(d, mode))),
                const SizedBox(height: 18),
                _modeChoices('Fan mode', d.fanModes, d.fan,
                  (mode) => apply(() => _change(d, mode, fan: true))),
                if (_busy) const Padding(
                  padding: EdgeInsets.only(top: 14),
                  child: LinearProgressIndicator()),
                if (_error != null) Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(_error!,
                    style: TextStyle(color: scheme.error))),
              ],
            ),
          );
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
    final colors = theme.colorScheme;

    Widget deviceCard(ResideoDevice d) {
      final directControl = d.online && (d.isCoolMode || d.isHeatMode) &&
          d.primaryTarget != null;
      return Card(
        key: ValueKey('resideo-card-${d.cacheId}'),
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.only(bottom: 10),
        color: colors.surface,
        child: InkWell(
          onTap: () => _details(d),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (_bulkMode) Checkbox(
                    value: _selected.contains(d.id),
                    onChanged: (_) => setState(() {
                      if (!_selected.add(d.id)) _selected.remove(d.id);
                    }),
                  ),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name, style: theme.textTheme.titleMedium,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(d.location,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  )),
                  Icon(Icons.circle, size: 9,
                    color: d.online ? Colors.green : colors.outline),
                  const SizedBox(width: 5),
                  Text(d.online ? 'Online' : 'Offline',
                      style: theme.textTheme.labelSmall),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, size: 19),
                ]),
                const SizedBox(height: 11),
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(flex: 3, child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ROOM', style: theme.textTheme.labelSmall),
                      Text(d.display(d.temperature),
                        key: ValueKey('resideo-room-${d.cacheId}'),
                        style: theme.textTheme.headlineSmall),
                    ],
                  )),
                  Expanded(flex: 4, child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.primaryTargetLabel,
                          style: theme.textTheme.labelSmall),
                      if (d.primaryTarget != null)
                        Text(d.display(d.primaryTarget),
                          key: ValueKey('resideo-target-${d.cacheId}'),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: colors.primary)),
                      if (d.primaryTarget == null)
                        Text(d.isAutoMode
                            ? '${d.display(d.heat)}–${d.display(d.cool)}'
                            : d.modeLabel,
                          maxLines: 1,
                          style: theme.textTheme.titleSmall),
                    ],
                  )),
                  if (directControl)
                    _temperatureControls(d, d.isHeatMode)
                  else
                    const SizedBox(width: 4),
                ]),
                const SizedBox(height: 9),
                Row(children: [
                  Icon(Icons.thermostat_outlined, size: 16,
                      color: colors.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Expanded(child: Text(
                      'Mode: ${d.modeLabel}  ·  Fan: ${d.fan}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall)),
                  if (_targetTimers.containsKey(d.cacheId) ||
                      _sendingTargets.contains(d.cacheId))
                    Text('Saving…', style: theme.textTheme.labelSmall
                        ?.copyWith(color: colors.primary)),
                ]),
              ],
            ),
          ),
        ),
      );
    }

    return ListView(
      key: const ValueKey('resideo-dashboard'),
      padding: const EdgeInsets.all(14),
      children: [
        if (!_configured) ...[
          const ListTile(
            leading: Icon(Icons.thermostat_outlined),
            title: Text('Connect Resideo'),
            subtitle: Text('Enter Consumer Key, Consumer Secret and Callback URL in API Integrations.'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Resideo API settings'),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const ResideoScreen(settingsOnly: true)));
              if (mounted) await _restore();
            },
          ),
        ] else ...[
          Row(children: [
            Expanded(child: Text(
              '${visible.length} thermostat${visible.length == 1 ? '' : 's'}',
              style: theme.textTheme.titleMedium)),
            TextButton.icon(
              key: const ValueKey('resideo-bulk-toggle'),
              icon: Icon(_bulkMode
                  ? Icons.close_rounded : Icons.checklist_rounded),
              onPressed: () => setState(() {
                _bulkMode = !_bulkMode;
                _selected.clear();
              }),
              label: Text(_bulkMode ? 'Done' : 'Select'),
            ),
          ]),
          if (_lastChecked != null || _busy)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _busy ? 'Updating thermostats in background…'
                  : 'Last checked ${TimeOfDay.fromDateTime(_lastChecked!).format(context)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (locations.length > 1)
            Padding(padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(spacing: 7, children: [
                for (final location in locations.entries)
                  FilterChip(
                    label: Text(location.value),
                    selected: _locations.contains(location.key),
                    onSelected: (_) => setState(() {
                      if (!_locations.add(location.key)) {
                        _locations.remove(location.key);
                      }
                    }),
                  ),
              ]),
            ),
          if (_devices.length > 5)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search rooms',
                  prefixIcon: Icon(Icons.search_rounded),
                  border: OutlineInputBorder(), isDense: true,
                ),
              ),
            ),
          if (_bulkMode) Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('${selected.length} selected',
                        style: theme.textTheme.labelLarge),
                    const Spacer(),
                    TextButton(onPressed: () => setState(() =>
                        _selected = visible.map((d) => d.id).toSet()),
                        child: const Text('All')),
                    TextButton(
                        onPressed: () => setState(() => _selected.clear()),
                        child: const Text('None')),
                  ]),
                  _modeChoices('Set system mode', const [
                    'Off', 'Cool', 'Heat', 'Auto'
                  ], null, (value) => _bulk(value, fan: false)),
                  const SizedBox(height: 10),
                  _modeChoices('Set fan mode', const [
                    'On', 'Auto', 'Circulate'
                  ], null, (value) => _bulk(value, fan: true)),
                ],
              ),
            ),
          ),
          for (final device in visible) deviceCard(device),
          if (_devices.isEmpty && !_busy)
            const Center(child: Padding(padding: EdgeInsets.all(28),
              child: Text('No thermostats found. Tap refresh to check again.'))),
          if (_busy && _devices.isEmpty) const Padding(
            padding: EdgeInsets.symmetric(vertical: 26),
            child: Center(child: CircularProgressIndicator())),
        ],
      ],
    );
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
