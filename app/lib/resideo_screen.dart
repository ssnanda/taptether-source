import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The same authenticated AJCore Resideo service used by AJOpsios.
/// Optional cloud functionality; independent of local computer/TV pairing.
class ResideoDevice {
  const ResideoDevice(this.id, this.name, this.location, this.locationId,
      this.temperature, this.setpoint, this.heat, this.cool,
      this.system, this.fan, this.systemModes, this.fanModes);
  final String id, name, location, locationId;
  final double? temperature, setpoint, heat, cool;
  final String system, fan;
  final List<String> systemModes, fanModes;

  static ResideoDevice? parse(Object? item) {
    if (item is! Map) return null;
    final id = item['id']?.toString() ?? '';
    if (id.isEmpty || id.length > 160) return null;
    String read(String key) => item[key]?.toString() ?? '';
    double? number(String key) =>
        item[key] is num ? (item[key] as num).toDouble() : null;
    List<String> modes(String key) => item[key] is List
        ? (item[key] as List).whereType<String>().toList() : [];
    return ResideoDevice(
      id, read('name').isEmpty ? 'Thermostat' : read('name'),
      read('location_name'), read('location_id'),
      number('indoor_temp'), number('set_temp'),
      number('heat_setpoint'), number('cool_setpoint'),
      read('mode'), read('fan_mode'),
      modes('available_system_modes'), modes('available_fan_modes'));
  }
}

List<ResideoDevice> parseResideoDevices(Object? payload) {
  if (payload is! Map || payload['devices'] is! List) {
    throw const FormatException('Unexpected Resideo device response.');
  }
  final result = (payload['devices'] as List)
      .map(ResideoDevice.parse).whereType<ResideoDevice>().toList();
  result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return result;
}

class ResideoRequestError implements Exception {
  const ResideoRequestError(this.message, [this.status = 0]);
  final String message;
  final int status;
  @override
  String toString() => message;
}

/// Passwords are used for sign-in only. AJOps session token is kept in iOS
/// Keychain / Android encrypted storage; no Resideo client secret is bundled.
class ResideoConnection {
  ResideoConnection({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device));
  static const defaultUrl = 'https://ncllcagents.com/wp-json/ajcore/v1';
  static const _urlKey = 'taptether.resideo.ajcore.url.v1';
  static const _tokenKey = 'taptether.resideo.ajcore.session.v1';
  final FlutterSecureStorage _storage;

  Future<String> url() async => await _storage.read(key: _urlKey) ?? defaultUrl;
  Future<String?> session() => _storage.read(key: _tokenKey);

  static String validateUrl(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        !uri.path.replaceFirst(RegExp(r'/+$'), '')
            .endsWith('/wp-json/ajcore/v1')) {
      throw const FormatException('Use an HTTPS URL ending in /wp-json/ajcore/v1.');
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), '')).toString();
  }

  Future<Object?> _send(String base, String route,
      {String? bearer, Map<String, Object?>? body}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final uri = Uri.parse(base + route);
      final request = body == null
          ? await client.getUrl(uri) : await client.postUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('X-AJCore-Client', 'mobile/1.0');
      if (bearer != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(const Duration(seconds: 30));
      final text = await utf8.decoder.bind(response).join()
          .timeout(const Duration(seconds: 30));
      Object? data;
      try {
        data = jsonDecode(text);
      } catch (_) {
        throw ResideoRequestError('Unexpected AJCore response.', response.statusCode);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = data is Map
            ? (data['message'] ?? data['error'])?.toString() : null;
        throw ResideoRequestError(
          response.statusCode == 401 ? 'Session expired. Connect again.'
            : (detail?.isNotEmpty == true ? detail! : 'AJCore request failed.'),
          response.statusCode);
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> connect(String address, String username, String password) async {
    final base = validateUrl(address);
    if (username.trim().isEmpty || password.isEmpty) {
      throw const FormatException('Enter AJOps username and password.');
    }
    final result = await _send(base, '/ops/auth/login',
        body: {'username': username.trim(), 'password': password});
    final token = result is Map ? result['token']?.toString() : null;
    if (token == null || token.isEmpty) {
      throw const ResideoRequestError('AJCore did not return a session.');
    }
    // A successful staff sign-in alone does not guarantee thermostat access.
    await _send(base, '/ops/upos-temps', bearer: token);
    await _storage.write(key: _urlKey, value: base);
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<(List<ResideoDevice>, bool)> load() async {
    final bearer = await session();
    if (bearer == null) {
      throw const ResideoRequestError('Connect your AJOps account first.');
    }
    final payload = await _send(await url(), '/ops/upos-temps', bearer: bearer);
    final settings = payload is Map ? payload['settings'] : null;
    return (parseResideoDevices(payload),
        settings is Map && settings['ready'] == true);
  }

  Future<void> setMode(String mode, {String? id, List<String>? selected,
      required bool fan}) async {
    final bearer = await session();
    if (bearer == null) {
      throw const ResideoRequestError('Connect your AJOps account first.');
    }
    final part = fan ? 'fan' : 'system';
    final route = id == null ? '/ops/upos-temps/$part'
        : '/ops/upos-temps/devices/${Uri.encodeComponent(id)}/$part';
    await _send(await url(), route, bearer: bearer, body: {
      'mode': mode, if (id == null && selected != null) 'device_ids': selected,
    });
  }

  Future<void> disconnect() async {
    final bearer = await session();
    if (bearer != null) {
      try {
        await _send(await url(), '/ops/auth/logout', bearer: bearer, body: {});
      } catch (_) {
        // Removing local access must succeed even if the network is offline.
      }
    }
    await _storage.delete(key: _tokenKey);
  }

  Future<void> expire() => _storage.delete(key: _tokenKey);
}

class ResideoScreen extends StatefulWidget {
  const ResideoScreen({super.key});
  @override
  State<ResideoScreen> createState() => _ResideoScreenState();
}

class _ResideoScreenState extends State<ResideoScreen> {
  final _api = ResideoConnection();
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _search = TextEditingController();
  List<ResideoDevice> _devices = [];
  Set<String> _selected = {};
  Set<String> _locations = {};
  bool _loading = true, _busy = false, _connected = false, _ready = false;
  String? _error;

  @override
  void initState() { super.initState(); _restore(); }

  @override
  void dispose() {
    _url.dispose(); _username.dispose(); _password.dispose(); _search.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final url = await _api.url();
      final session = await _api.session();
      if (!mounted) return;
      _url.text = url;
      setState(() { _loading = false; _connected = session != null; });
      if (session != null) await _refresh();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false; _error = 'Cannot open secure account storage.';
        });
      }
    }
  }

  String _friendly(Object error) {
    if (error is ResideoRequestError) return error.message;
    if (error is FormatException) return error.message;
    if (error is SocketException || error is HandshakeException ||
        error is HttpException) {
      return 'Cannot reach AJCore securely.';
    }
    return 'Request failed. Check connection and try again.';
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await work();
    } catch (error) {
      if (error is ResideoRequestError && error.status == 401) {
        await _api.expire();
        if (mounted) setState(() { _connected = false; _devices = []; });
      }
      if (mounted) setState(() => _error = _friendly(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
    await _api.connect(_url.text, _username.text, _password.text);
    _password.clear();
    if (!mounted) return;
    setState(() => _connected = true);
    await _load();
  });

  Future<void> _load() async {
    final (devices, ready) = await _api.load();
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _ready = ready;
      final ids = devices.map((d) => d.id).toSet();
      if (_selected.isEmpty) _selected = ids;
      _selected = _selected.intersection(ids);
      final locations = devices.map((d) => d.locationId).toSet();
      if (_locations.isEmpty) _locations = locations;
      _locations = _locations.intersection(locations);
    });
  }

  Future<void> _refresh() => _run(_load);

  Future<void> _disconnect() => _run(() async {
    await _api.disconnect();
    if (mounted) {
      setState(() {
        _connected = false; _devices = []; _selected = {};
        _locations = {}; _ready = false;
      });
    }
  });

  Future<void> _change(String mode, {String? id, required bool fan}) =>
      _run(() async {
        final ids = id == null ? _devices.where((d) =>
            _locations.contains(d.locationId) && _selected.contains(d.id))
            .map((d) => d.id).toList() : null;
        if (id == null && ids!.isEmpty) return;
        await _api.setMode(mode, id: id, selected: ids, fan: fan);
        await _load();
      });

  String _temp(double? x) => x == null ? '—' : '${x.round()}°F';

  Widget _modes(String title, List<String> values, String? current,
      void Function(String) select) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 7),
      Wrap(spacing: 6, runSpacing: 4, children: [
        for (final value in values) ChoiceChip(
          label: Text(value),
          selected: value.toLowerCase() == current?.toLowerCase(),
          onSelected: _busy ? null : (_) => select(value),
        ),
      ]),
    ],
  );

  void _details(ResideoDevice device) {
    showModalBottomSheet<void>(context: context, isScrollControlled: true,
      showDragHandle: true, builder: (sheet) => StatefulBuilder(
        builder: (ctx, redraw) {
          final current = _devices.where((d) => d.id == device.id).firstOrNull ?? device;
          return SafeArea(child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(current.name, style: Theme.of(ctx).textTheme.titleLarge),
                Text(current.location, style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 14),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _stat('Indoor', _temp(current.temperature)),
                  _stat('Set', _temp(current.setpoint)),
                  _stat('Heat', _temp(current.heat)),
                  _stat('Cool', _temp(current.cool)),
                ]),
                const SizedBox(height: 18),
                _modes('System', current.systemModes, current.system,
                    (v) async {
                      await _change(v, id: current.id, fan: false);
                      if (ctx.mounted) redraw(() {});
                    }),
                const SizedBox(height: 14),
                _modes('Fan', current.fanModes, current.fan, (v) async {
                  await _change(v, id: current.id, fan: true);
                  if (ctx.mounted) redraw(() {});
                }),
                if (_busy) const LinearProgressIndicator(),
            ]),
          ));
        }));
  }

  Widget _stat(String name, String value) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(name, style: Theme.of(context).textTheme.labelSmall),
      Text(value, style: Theme.of(context).textTheme.titleMedium),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    final visible = _devices.where((d) =>
        _locations.contains(d.locationId) &&
        (query.isEmpty || d.name.toLowerCase().contains(query) ||
         d.location.toLowerCase().contains(query))).toList();
    final chosen = visible.where((d) => _selected.contains(d.id)).toList();
    final locations = <String, String>{
      for (final d in _devices) d.locationId:
          d.location.isEmpty ? d.locationId : d.location,
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Resideo Thermostats'), actions: [
        if (_connected) IconButton(tooltip: 'Refresh',
          icon: const Icon(Icons.refresh), onPressed: _busy ? null : _refresh),
        if (_connected) IconButton(tooltip: 'Disconnect',
          icon: const Icon(Icons.logout_outlined),
          onPressed: _busy ? null : _disconnect),
      ]),
      body: _loading ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
        Card(color: theme.colorScheme.primaryContainer, child: Padding(
          padding: const EdgeInsets.all(14), child: Row(children: [
            const Icon(Icons.thermostat),
            const SizedBox(width: 12),
            const Expanded(child: Text(
              'Optional cloud control using your existing AJOps Resideo connection.')),
          ]),
        )),
        if (_error != null) Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
        if (!_connected) ...[
          const SizedBox(height: 12),
          TextField(controller: _url, keyboardType: TextInputType.url,
            autocorrect: false, decoration: const InputDecoration(
              labelText: 'AJCore API URL', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: _username, autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'AJOps username', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: _password, obscureText: true,
            onSubmitted: (_) { if (!_busy) _connect(); },
            decoration: const InputDecoration(
              labelText: 'Password', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _busy ? null : _connect,
            icon: const Icon(Icons.link), label: const Text('Connect')),
          const Text('Password is never saved; the session stays in secure storage.'),
        ] else ...[
          if (!_ready) const Padding(padding: EdgeInsets.all(12),
            child: Text('Resideo is not configured on AJCore.')),
          if (_devices.isNotEmpty) ...[
            const SizedBox(height: 12),
            TextField(controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Search thermostats',
                prefixIcon: Icon(Icons.search), border: OutlineInputBorder())),
            if (locations.length > 1) Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(spacing: 6, children: [
                for (final entry in locations.entries) FilterChip(
                  label: Text(entry.value),
                  selected: _locations.contains(entry.key),
                  onSelected: (_) => setState(() {
                    if (!_locations.add(entry.key)) _locations.remove(entry.key);
                  }),
                ),
              ]),
            ),
            Row(children: [
              Text('${chosen.length} selected',
                  style: theme.textTheme.labelLarge),
              const Spacer(),
              TextButton(onPressed: () => setState(() =>
                  _selected = _devices.map((d) => d.id).toSet()),
                  child: const Text('All')),
              TextButton(onPressed: () => setState(() => _selected = {}),
                  child: const Text('None')),
            ]),
            _modes('System · Selected', const ['Off', 'Cool', 'Heat', 'Auto'],
                null, (v) => _change(v, fan: false)),
            const SizedBox(height: 10),
            _modes('Fan · Selected', const ['On', 'Auto', 'Circulate'],
                null, (v) => _change(v, fan: true)),
            const SizedBox(height: 16),
          ],
          for (final device in visible) Card(
            clipBehavior: Clip.antiAlias, child: ListTile(
              leading: Checkbox(value: _selected.contains(device.id),
                onChanged: (_) => setState(() {
                  if (!_selected.add(device.id)) _selected.remove(device.id);
                })),
              title: Text(device.name),
              subtitle: Text('${device.location} · ${device.system} · Fan ${device.fan}'),
              trailing: Column(mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(_temp(device.temperature),
                      style: theme.textTheme.titleMedium),
                  Text('Set ${_temp(device.setpoint)}',
                      style: theme.textTheme.labelSmall),
                ]),
              onTap: () => _details(device),
            )),
          if (_ready && _devices.isEmpty)
            const Padding(padding: EdgeInsets.all(30),
                child: Center(child: Text('No thermostats found.'))),
          if (_busy) const LinearProgressIndicator(),
        ],
      ]),
    );
  }
}
