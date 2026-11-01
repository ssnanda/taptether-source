import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'resideo_api.dart';
import 'resideo_oauth_screen.dart';

/// Dashboard shortcut and Settings → API Integrations share one connection,
/// but the dashboard never displays developer credentials.
class ResideoScreen extends StatefulWidget {
  const ResideoScreen({super.key, this.settingsOnly = false,
      this.refreshOnOpen = true});
  final bool settingsOnly;
  final bool refreshOnOpen;

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
  final Set<String> _collapsedLocations = {};
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _listeningSearch = false;
  List<String> _locationOrder = [];
  List<String> _deviceOrder = [];
  bool _layoutSaved = false;
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
    unawaited(_speech.cancel());
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
      final savedLayout = await _api.dashboardLayout();
      if (!mounted) return;
      if (savedLayout != null) {
        _layoutSaved = true;
        _locations = (savedLayout['locations'] as List? ?? const [])
            .whereType<String>().toSet();
        _locationOrder = (savedLayout['locationOrder'] as List? ?? const [])
            .whereType<String>().toList();
        _deviceOrder = (savedLayout['deviceOrder'] as List? ?? const [])
            .whereType<String>().toList();
      }
      if (c.usable && !widget.settingsOnly && _devices.isEmpty) {
        final (cached, checkedAt) = await _api.cachedDevices();
        if (!mounted) {
          return;
        }
        if (cached.isNotEmpty) {
          setState(() {
            _devices = cached;
            _lastChecked = checkedAt;
            if (!_layoutSaved) {
              _locations = cached.map((d) => d.locationId).toSet();
            }
            _loading = false;
          });
        }
      }
      setState(() {
        _configured = c.usable;
        _loading = false;
      });
      if (!widget.settingsOnly && c.usable && widget.refreshOnOpen) {
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
      _locations = {};
      _locationOrder = [];
      _deviceOrder = [];
      _layoutSaved = false;
      _collapsedLocations.clear();
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
      if (!_layoutSaved) {
        if (_locations.isEmpty) _locations = locations;
        _locations = _locations.intersection(locations);
      }
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
    if (_sendingTargets.contains(key)) {
      return;
    }
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
    if (current == null || _sendingTargets.contains(key)) {
      return;
    }
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
    if (value == null || !d.online) {
      return const SizedBox.shrink();
    }
    final sending = _sendingTargets.contains(d.cacheId);
    final accent = d.isCoolMode ? const Color(0xFF0875CB)
        : d.isHeatMode ? const Color(0xFFC65A25)
        : const Color(0xFF38698D);
    final buttonStyle = IconButton.styleFrom(
      backgroundColor: accent.withValues(alpha: .10),
      foregroundColor: accent,
      minimumSize: const Size(40, 40),
      maximumSize: const Size(40, 40),
      padding: EdgeInsets.zero,
      iconSize: 21,
      shape: CircleBorder(side: BorderSide(
        color: accent.withValues(alpha: .18))),
    );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        style: buttonStyle,
        key: ValueKey('resideo-decrease-${d.cacheId}-${heating ? 'heat' : 'cool'}'),
        tooltip: 'Lower ${d.name} ${heating ? 'heat' : 'cool'} target',
        icon: const Icon(Icons.remove_rounded),
        onPressed: sending ? null : () => _adjustTarget(d, heating, -1),
      ),
      const SizedBox(width: 2),
      IconButton(
        style: buttonStyle,
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
    if (chosen.isEmpty || _busy) {
      return;
    }
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
    if (approved != true || !mounted) {
      return;
    }
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
      if (!mounted) {
        return;
      }
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
            if (_busy) {
              return;
            }
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
                  if (d.humidity != null)
                    Text('Indoor humidity: ${d.humidity!.toStringAsFixed(0)}%'),
                  if (d.outdoorTemperature != null)
                    Text('Outside: ${d.display(d.outdoorTemperature)}'),
                  if (d.outdoorHumidity != null)
                    Text('Outdoor humidity: ${d.outdoorHumidity!.toStringAsFixed(0)}%'),
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


  List<String> _orderedLocations(Iterable<String> ids) {
    final remainder = ids.toSet();
    final result = <String>[];
    for (final id in _locationOrder) {
      if (remainder.remove(id)) {
        result.add(id);
      }
    }
    result.addAll(remainder.toList()..sort());
    return result;
  }

  List<ResideoDevice> _orderedDevices(Iterable<ResideoDevice> devices) {
    final result = devices.toList();
    result.sort((a, b) {
      final first = _deviceOrder.indexOf(a.cacheId);
      final second = _deviceOrder.indexOf(b.cacheId);
      if (first >= 0 && second >= 0) return first.compareTo(second);
      if (first >= 0) return -1;
      if (second >= 0) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return result;
  }

  Future<void> _saveDashboardLayout() async {
    try {
      await _api.saveDashboardLayout({
        'locations': _locations.toList(),
        'locationOrder': _locationOrder,
        'deviceOrder': _deviceOrder,
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save thermostat layout on this device.');
      }
    }
  }

  Future<void> _customizeDashboard() async {
    final names = <String, String>{
      for (final d in _devices)
        d.locationId: d.location.isEmpty ? d.locationId : d.location,
    };
    final locationOrder = _orderedLocations(names.keys);
    final deviceOrder = _orderedDevices(_devices).map((d) => d.cacheId).toList();
    final enabled = _locations.intersection(names.keys.toSet());
    final byId = <String, ResideoDevice>{
      for (final d in _devices) d.cacheId: d,
    };
    void shift(List<String> items, String key, int direction) {
      final from = items.indexOf(key);
      final to = from + direction;
      if (from < 0 || to < 0 || to >= items.length) return;
      final temp = items[from];
      items[from] = items[to];
      items[to] = temp;
    }
    void shiftDevice(String key, String locationId, int direction) {
      final local = deviceOrder.where((id) =>
          byId[id]?.locationId == locationId).toList();
      final index = local.indexOf(key);
      final neighborIndex = index + direction;
      if (index < 0 || neighborIndex < 0 ||
          neighborIndex >= local.length) {
        return;
      }
      final other = local[neighborIndex];
      final a = deviceOrder.indexOf(key);
      final b = deviceOrder.indexOf(other);
      deviceOrder[a] = other;
      deviceOrder[b] = key;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, redraw) {
          List<ResideoDevice> devicesIn(String locationId) {
            final result = _devices.where((d) =>
                d.locationId == locationId).toList();
            result.sort((a, b) => deviceOrder.indexOf(a.cacheId)
                .compareTo(deviceOrder.indexOf(b.cacheId)));
            return result;
          }

          Widget arrows(int index, int count, void Function(int) move) =>
              Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Move up',
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  onPressed: index == 0 ? null : () => redraw(() => move(-1)),
                ),
                IconButton(
                  tooltip: 'Move down',
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  onPressed: index >= count - 1
                      ? null : () => redraw(() => move(1)),
                ),
              ]);

          return SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .75,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(children: [
                  Expanded(child: Text('Customize thermostats',
                      style: Theme.of(sheetContext).textTheme.titleLarge)),
                  TextButton(onPressed: () => redraw(() {
                    enabled..clear()..addAll(names.keys);
                  }), child: const Text('Show all')),
                ]),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Choose locations and use arrows to set the order.'),
                ),
              ),
              Expanded(child: ListView(children: [
                for (final locationId in locationOrder) ...[
                  CheckboxListTile(
                    key: ValueKey('resideo-layout-location-$locationId'),
                    value: enabled.contains(locationId),
                    title: Text(names[locationId] ?? locationId),
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (selected) => redraw(() {
                      if (selected == true) {
                        enabled.add(locationId);
                      } else if (enabled.length > 1) {
                        enabled.remove(locationId);
                      }
                    }),
                    secondary: arrows(
                      locationOrder.indexOf(locationId),
                      locationOrder.length,
                      (direction) => shift(locationOrder, locationId, direction),
                    ),
                  ),
                  for (final device in devicesIn(locationId))
                    Padding(
                      padding: const EdgeInsets.only(left: 26),
                      child: ListTile(
                        dense: true,
                        title: Text(device.name),
                        leading: const Icon(Icons.thermostat_outlined, size: 20),
                        trailing: arrows(
                          devicesIn(locationId).indexWhere(
                              (d) => d.cacheId == device.cacheId),
                          devicesIn(locationId).length,
                          (direction) => shiftDevice(
                              device.cacheId, locationId, direction),
                        ),
                      ),
                    ),
                  const Divider(height: 8),
                ],
              ])),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                child: SizedBox(width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('resideo-save-layout'),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save selection & order'),
                    onPressed: enabled.isEmpty ? null : () async {
                      try {
                        await _api.saveDashboardLayout({
                          'locations': enabled.toList(),
                          'locationOrder': locationOrder,
                          'deviceOrder': deviceOrder,
                        });
                        if (!mounted || !sheetContext.mounted) return;
                        setState(() {
                          _locations = Set.of(enabled);
                          _locationOrder = List.of(locationOrder);
                          _deviceOrder = List.of(deviceOrder);
                          _layoutSaved = true;
                        });
                        Navigator.pop(sheetContext);
                      } catch (_) {
                        if (sheetContext.mounted) {
                          ScaffoldMessenger.of(sheetContext).showSnackBar(
                            const SnackBar(content: Text(
                                'Unable to save thermostat layout.')),
                          );
                        }
                      }
                    },
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }


  Future<void> _voiceSearch() async {
    if (_listeningSearch) {
      await _speech.stop();
      if (mounted) {
        setState(() => _listeningSearch = false);
      }
      return;
    }
    try {
      final ready = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) {
            return;
          }
          if (status == 'done' || status == 'notListening') {
            setState(() => _listeningSearch = false);
          }
        },
        onError: (_) {
          if (mounted) {
            setState(() {
              _listeningSearch = false;
              _error = 'Voice search stopped. Try typing a room name.';
            });
          }
        },
      );
      if (!ready || !mounted) {
        if (mounted) {
          setState(() => _error =
              'Speech recognition unavailable. Use the search field.');
        }
        return;
      }
      setState(() => _listeningSearch = true);
      await _speech.listen(
        onResult: (result) {
          if (mounted) {
            setState(() => _search.text = result.recognizedWords);
          }
        },
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _listeningSearch = false;
          _error = 'Voice search unavailable. Use the search field.';
        });
      }
    }
  }

  Widget _dashboard() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final query = _search.text.trim().toLowerCase();
    final locations = <String, String>{
      for (final d in _devices)
        d.locationId: d.location.isEmpty ? d.locationId : d.location,
    };
    final orderedLocations = _orderedLocations(locations.keys)
        .where(_locations.contains).toList();
    final visible = _orderedDevices(_devices.where((d) =>
        _locations.contains(d.locationId) &&
        (query.isEmpty || d.name.toLowerCase().contains(query) ||
          d.location.toLowerCase().contains(query))));
    final selected = visible.where((d) => _selected.contains(d.id)).toList();
    final onlineCount = visible.where((d) => d.online).length;
    final allOnline = visible.isNotEmpty && onlineCount == visible.length;
    final summaryLocation = orderedLocations.length == 1
        ? (locations[orderedLocations.first] ?? '')
        : '${orderedLocations.length} Locations';
    final lastCheck = _lastChecked == null ? 'Checking…'
        : 'Checked ${TimeOfDay.fromDateTime(_lastChecked!).format(context)}';
    final allCooling = visible.isNotEmpty &&
        visible.every((d) => d.isCoolMode);
    final allHeating = visible.isNotEmpty &&
        visible.every((d) => d.isHeatMode);
    final summaryMode = allCooling ? 'Cooling'
        : allHeating ? 'Heating'
        : visible.isNotEmpty && visible.every((d) => d.isAutoMode) ? 'Auto'
        : visible.isNotEmpty && visible.every((d) => d.isOffMode) ? 'Off'
        : visible.isEmpty ? 'No devices' : 'Mixed Modes';

    Widget footerItem(IconData icon, String label, Color color) {
      return Expanded(child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 3),
          Flexible(child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, maxLines: 1,
              style: TextStyle(color: color,
                fontSize: 12, fontWeight: FontWeight.w600)),
          )),
        ],
      ));
    }

    Widget deviceCard(ResideoDevice d) {
      final cooling = d.isCoolMode;
      final heating = d.isHeatMode;
      final accent = cooling ? const Color(0xFF0875CB)
          : heating ? const Color(0xFFC65A25)
          : const Color(0xFF38698D);
      final tint = cooling
          ? const [Color(0xFFF4FAFF), Color(0xFFEAF5FF)]
          : heating ? const [Color(0xFFFFF9F4), Color(0xFFFFEFE4)]
          : const [Color(0xFFF9FBFE), Color(0xFFF1F5FA)];
      final directControl = d.online && (cooling || heating) &&
          d.primaryTarget != null;
      final statusColor = d.online
          ? const Color(0xFF16A13B) : const Color(0xFF8A96A5);
      return Container(
        key: ValueKey('resideo-card-${d.cacheId}'),
        margin: const EdgeInsets.only(bottom: 7),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: tint),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: accent.withValues(alpha: .17)),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: () => _details(d),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 9, 9),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    if (_bulkMode) Checkbox(
                      visualDensity: VisualDensity.compact,
                      value: _selected.contains(d.id),
                      onChanged: (_) => setState(() {
                        if (!_selected.add(d.id)) {
                          _selected.remove(d.id);
                        }
                      }),
                    ),
                    Icon(Icons.thermostat_outlined, size: 18,
                      color: accent),
                    const SizedBox(width: 6),
                    Expanded(child: Text(d.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF14273E)))),
                    Semantics(
                      label: d.online ? 'Online' : 'Offline',
                      child: Tooltip(
                        message: d.online ? 'Online' : 'Offline',
                        child: Icon(Icons.circle, size: 9,
                          color: statusColor),
                      ),
                    ),
                    if (!d.online) ...[
                      const SizedBox(width: 4),
                      Text('Offline',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: statusColor)),
                    ],
                    const SizedBox(width: 3),
                    const Icon(Icons.chevron_right_rounded, size: 18,
                      color: Color(0xFF384F65)),
                  ]),
                  const SizedBox(height: 7),
                  Row(children: [
                    Expanded(flex: 3, child: Text(
                      d.display(d.temperature),
                      key: ValueKey('resideo-room-${d.cacheId}'),
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 25, fontWeight: FontWeight.w800,
                        color: Color(0xFF132840)))),
                    Container(width: 1, height: 32,
                      color: accent.withValues(alpha: .20)),
                    const SizedBox(width: 9),
                    Expanded(flex: 3, child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(d.isAutoMode ? 'Auto range' : 'Set to',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: const Color(0xFF3C4D62),
                            fontSize: 10)),
                        Text(d.primaryTarget == null
                          ? (d.isAutoMode
                              ? '${d.display(d.heat)}–${d.display(d.cool)}'
                              : d.isOffMode ? 'Off' : '—')
                          : d.display(d.primaryTarget),
                          key: ValueKey('resideo-target-${d.cacheId}'),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: d.isAutoMode ? 14 : 23,
                            fontWeight: FontWeight.w800, color: accent)),
                      ],
                    )),
                    if (directControl) _temperatureControls(d, heating),
                  ]),
                  const SizedBox(height: 6),
                  Divider(height: 1, color: accent.withValues(alpha: .13)),
                  const SizedBox(height: 6),
                  Row(children: [
                    footerItem(
                      cooling ? Icons.ac_unit_rounded
                          : heating ? Icons.wb_sunny_outlined
                          : Icons.thermostat_outlined,
                      cooling ? 'Cool' : heating ? 'Heat' : d.modeLabel,
                      accent),
                    Container(width: 1, height: 16,
                      color: accent.withValues(alpha: .13)),
                    footerItem(Icons.air_rounded, d.fan,
                      const Color(0xFF293C50)),
                    if (d.humidity != null) ...[
                      Container(width: 1, height: 16,
                        color: accent.withValues(alpha: .13)),
                      footerItem(Icons.water_drop_outlined,
                        '${d.humidity!.toStringAsFixed(0)}%',
                        const Color(0xFF293C50)),
                    ],
                    if (d.outdoorTemperature != null) ...[
                      Container(width: 1, height: 16,
                        color: accent.withValues(alpha: .13)),
                      footerItem(Icons.cloud_outlined,
                        d.display(d.outdoorTemperature),
                        const Color(0xFF293C50)),
                    ],
                  ]),
                  if (_targetTimers.containsKey(d.cacheId) ||
                      _sendingTargets.contains(d.cacheId))
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text('Saving…',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: accent)),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ListView(
      key: const ValueKey('resideo-dashboard'),
      padding: const EdgeInsets.all(12),
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
              if (mounted) {
                await _restore();
              }
            },
          ),
        ] else ...[
          Container(
            key: const ValueKey('resideo-summary-banner'),
            padding: const EdgeInsets.fromLTRB(15, 17, 12, 17),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                begin: Alignment.topLeft, end: Alignment.bottomRight,
                colors: [Color(0xFFF1F0FF), Color(0xFFE0F2FF),
                  Color(0xFFE2EDFF)],
              ),
            ),
            child: Row(children: [
              const Icon(Icons.home_outlined, size: 32,
                  color: Color(0xFF183D6B)),
              const SizedBox(width: 10),
              Expanded(flex: 3, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${visible.length} Thermostats',
                    key: const ValueKey('resideo-summary-count'),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF142A46))),
                  const SizedBox(height: 4),
                  Text('$summaryLocation · $lastCheck',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF36475D))),
                ],
              )),
              Container(height: 46, width: 1,
                color: const Color(0xFFB7D1E6)),
              const SizedBox(width: 10),
              Expanded(flex: 2, child: Column(children: [
                Icon(allCooling ? Icons.ac_unit_rounded
                    : allHeating ? Icons.wb_sunny_outlined
                    : Icons.thermostat_outlined,
                    size: 24, color: const Color(0xFF0875CB)),
                const SizedBox(height: 4),
                Text(summaryMode, maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF172C46))),
                const SizedBox(height: 3),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.circle, size: 8,
                    color: allOnline ? const Color(0xFF16B23B)
                      : const Color(0xFF8294A8)),
                  const SizedBox(width: 4),
                  Flexible(child: Text(allOnline ? 'All Online'
                      : '$onlineCount/${visible.length} Online',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600))),
                ]),
              ])),
            ]),
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final locationId in _orderedLocations(locations.keys)) ...[
                FilterChip(
                  key: ValueKey('resideo-filter-$locationId'),
                  label: Text(locations[locationId] ?? locationId),
                  selected: _locations.contains(locationId),
                  showCheckmark: true,
                  selectedColor: const Color(0xFFD0EEE6),
                  onSelected: (_) {
                    if (_locations.length == 1 &&
                        _locations.contains(locationId)) {
                      return;
                    }
                    setState(() {
                      if (!_locations.add(locationId)) {
                        _locations.remove(locationId);
                      }
                      _layoutSaved = true;
                    });
                    _saveDashboardLayout();
                  },
                ),
                const SizedBox(width: 6),
              ],
              Container(width: 1, height: 25,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: scheme.outlineVariant),
              OutlinedButton.icon(
                key: const ValueKey('resideo-customize'),
                icon: const Icon(Icons.swap_vert_rounded, size: 19),
                label: const Text('Arrange'),
                onPressed: _devices.isEmpty ? null : _customizeDashboard),
              const SizedBox(width: 7),
              OutlinedButton.icon(
                key: const ValueKey('resideo-bulk-toggle'),
                icon: Icon(_bulkMode ? Icons.close_rounded
                    : Icons.check_box_outlined, size: 19),
                label: Text(_bulkMode ? 'Done' : 'Select'),
                onPressed: () => setState(() {
                  _bulkMode = !_bulkMode;
                  _selected.clear();
                })),
              const SizedBox(width: 6),
              IconButton.outlined(
                key: const ValueKey('resideo-settings'),
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Resideo API settings',
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const ResideoScreen(settingsOnly: true)));
                  if (mounted) {
                    await _restore();
                  }
                }),
            ]),
          ),
          const SizedBox(height: 13),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search thermostats…',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: IconButton(
                key: const ValueKey('resideo-voice-search'),
                tooltip: _listeningSearch ? 'Stop listening' : 'Voice search',
                icon: Icon(_listeningSearch
                    ? Icons.mic_rounded : Icons.mic_none_rounded),
                onPressed: _voiceSearch,
              ),
              filled: true,
              fillColor: scheme.surface,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(27),
                borderSide: BorderSide(color: scheme.outlineVariant)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(27),
                borderSide: BorderSide(color: scheme.outlineVariant)),
            ),
          ),
          const SizedBox(height: 16),
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
          for (final locationId in orderedLocations)
            if (visible.any((d) => d.locationId == locationId))
              Container(
                key: ValueKey('resideo-location-$locationId'),
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.fromLTRB(9, 3, 9, 1),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7FAFE),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: const Color(0xFFD5DFEA)),
                  boxShadow: const [BoxShadow(
                    color: Color(0x0B132B46), blurRadius: 10,
                    offset: Offset(0, 3))],
                ),
                child: Column(children: [
                  InkWell(
                    key: ValueKey('resideo-group-toggle-$locationId'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() {
                      if (!_collapsedLocations.add(locationId)) {
                        _collapsedLocations.remove(locationId);
                      }
                    }),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(7, 12, 7, 12),
                      child: Row(children: [
                        const Icon(Icons.location_on_outlined, size: 23,
                            color: Color(0xFF173B65)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(locations[locationId] ?? locationId,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: const Color(0xFF1A2942),
                            fontWeight: FontWeight.w800))),
                        Text('${visible.where((d) => d.locationId == locationId).length} Thermostats',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF2B3B51))),
                        const SizedBox(width: 5),
                        Icon(_collapsedLocations.contains(locationId)
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_up_rounded),
                      ]),
                    ),
                  ),
                  if (!_collapsedLocations.contains(locationId))
                    for (final device in visible.where(
                        (d) => d.locationId == locationId))
                      deviceCard(device),
                ]),
              ),
          if (visible.isEmpty && !_busy)
            const Center(child: Padding(padding: EdgeInsets.all(28),
              child: Text('No thermostats for this selection. Tap Arrange to choose locations.'))),
          if (_busy && _devices.isEmpty)
            const Padding(
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
        centerTitle: true,
        title: widget.settingsOnly
            ? const Text('Resideo API')
            : const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.thermostat_outlined, color: Color(0xFF0A65B9)),
                SizedBox(width: 8),
                Text('Thermostats',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              ]),
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
