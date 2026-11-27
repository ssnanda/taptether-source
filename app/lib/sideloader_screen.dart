import 'dart:async';
import 'package:flutter/material.dart';
import 'sideloader_api.dart';
import 'sideloader_background.dart';

/// Native Settings & More integration; the SideLoader server stays independent.
class SideLoaderScreen extends StatefulWidget {
  const SideLoaderScreen({super.key});
  @override
  State<SideLoaderScreen> createState() => _SideLoaderScreenState();
}

class _SideLoaderScreenState extends State<SideLoaderScreen>
    with WidgetsBindingObserver {
  final _api = SideLoaderApi();
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _initializing = true, _busy = false, _connected = false;
  bool _remember = true, _sendingCode = false, _polling = false;
  String _deviceId = '', _error = '', _message = '', _scanError = '';
  String _sourcesError = '', _activeApp = '';
  SideLoaderState? _state;
  List<SideLoaderPhoneApp>? _inventory;
  List<SideLoaderSourceApp> _sources = [];
  SideLoaderJob? _job;
  _Action? _pending;
  Timer? _timer;

  SideLoaderDevice? get _device {
    final devices = _state?.devices ?? const <SideLoaderDevice>[];
    for (final device in devices) {
      if (device.udid == _deviceId) return device;
    }
    return devices.isEmpty ? null : devices.first;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restore());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _connected) unawaited(_refresh());
  }

  Future<void> _restore() async {
    try {
      final saved = await _api.savedCredentials();
      if (saved != null) {
        _deviceId = await _api.savedDevice() ?? '';
        _server.text = saved.url;
        _user.text = saved.user;
        _password.text = saved.password;
        await _connect();
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Saved login unavailable: $e');
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() { _busy = true; _error = ''; });
    try {
      await _api.login(_server.text, _user.text, _password.text,
          remember: _remember);
      if (!mounted) return;
      setState(() => _connected = true);
      await _load();
      unawaited(SideLoaderBackground.instance.schedule());
      unawaited(SideLoaderBackground.instance.requestPermission()
          .catchError((_) {}));
    } catch (e) {
      if (mounted) {
        setState(() {
          _connected = false;
          _error = 'Cannot connect: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final state = await _api.state();
    if (!mounted) return;
    final choice = sideLoaderPreferredDevice(state.devices, _deviceId);
    if (choice.isNotEmpty) {
      unawaited(_api.saveDevice(choice));
      // TapTether initiates the server's renewal/update check while the
      // phone is on the Mac's network; failures surface via alerts.
      unawaited(_api.autoRun(choice).then<void>((_) {}, onError: (_) {}));
    }
    setState(() {
      _state = state;
      _deviceId = choice;
      _scanError = '';
      _sourcesError = '';
      _inventory = null;
    });
    if (choice.isNotEmpty) {
      try {
        final result = await _api.inventory(choice);
        if (mounted && choice == _deviceId) setState(() => _inventory = result);
      } catch (e) {
        if (mounted && choice == _deviceId) {
          setState(() => _scanError = 'iPhone scan failed: $e');
        }
      }
    }
    try {
      final catalog = await _api.sources();
      if (mounted) setState(() => _sources = catalog);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sources = [];
          _sourcesError = 'Sources unavailable: $e';
        });
      }
    }
    final job = await _api.currentJob();
    if (!mounted) return;
    if (job?.running == true) {
      setState(() { _job = job; _activeApp = job!.title; });
      _startPolling();
    }
  }

  Future<void> _refresh() async {
    if (!_connected || _busy) return;
    setState(() { _busy = true; _error = ''; });
    try {
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = 'Refresh failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _installed(SideLoaderApp app) =>
      _inventory?.any((row) => row.matches(app.bundleId)) == true;

  bool _canSign(SideLoaderApp app) =>
      _device?.reachable == true &&
      _inventory != null && _installed(app) &&
      app.targetFor(_deviceId) != null && !_busy &&
      _job?.running != true && _state?.blocked != true;

  List<SideLoaderApp> get _apps {
    final result = (_state?.apps ?? []).where((app) {
      final target = app.targetFor(_deviceId);
      if (target == null) return false;
      return _inventory == null ? target.installation == 'installed' : _installed(app);
    }).toList();
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  void _choose(SideLoaderApp app, bool latest) {
    if (!_canSign(app)) return;
    final source = latest ? sideLoaderLatestSource(_sources, app.bundleId) : null;
    if (latest && source == null) {
      setState(() => _error = 'No saved source matches this app bundle ID.');
      return;
    }
    setState(() { _pending = _Action(app, source); _error = ''; _message = ''; });
  }

  Future<void> _confirm() async {
    final action = _pending, device = _device;
    if (action == null || device == null || !_canSign(action.app)) return;
    setState(() { _busy = true; _error = ''; });
    try {
      var appId = action.app.id;
      if (action.source != null) {
        appId = await _api.reinstallLatest(action.source!, device.udid);
      }
      // The signing request is initiated only after this explicit user action.
      final id = await _api.reSign(device.udid, appId);
      if (!mounted) return;
      setState(() {
        _pending = null;
        _activeApp = action.app.name;
        _job = SideLoaderJob(id, 'Signing', true, null, 'signin', null,
            false, false, '', null, '');
        _message = action.source == null ?
            'Re-sign started.' : 'Latest IPA saved; signing started.';
      });
      _startPolling();
    } catch (e) {
      if (mounted) setState(() => _error = 'Signing not started: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2),
        (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  Future<void> _poll() async {
    if (!mounted || _polling || !_connected) return;
    _polling = true;
    try {
      final result = await _api.currentJob();
      if (!mounted) return;
      if (result == null || (_job != null && result.id != _job!.id)) {
        _timer?.cancel();
        setState(() => _error =
            'Signing job unavailable. Check SideLoader server Activity.');
        return;
      }
      setState(() => _job = result);
      if (!result.running) {
        _timer?.cancel();
        setState(() => _message = result.rc == 0
            ? 'Installation completed.' : 'Signing failed; review server Activity.');
        if (result.rc == 0) unawaited(_refresh());
      }
    } catch (e) {
      _timer?.cancel();
      if (mounted) setState(() => _error = 'Cannot monitor job: $e');
    } finally {
      _polling = false;
    }
  }

  Future<void> _verify() async {
    final job = _job;
    if (_sendingCode || job == null || !job.running ||
        !job.needsInput || !job.acceptsInput ||
        !RegExp(r'^[0-9]{6}$').hasMatch(_code.text.trim())) {
      return;
    }
    setState(() { _sendingCode = true; _error = ''; });
    try {
      final current = await _api.currentJob();
      if (current == null || current.id != job.id ||
          !current.running || !current.needsInput || !current.acceptsInput) {
        throw const SideLoaderException('Apple verification has expired.');
      }
      await _api.sendCode(_code.text.trim());
      _code.clear();
      if (mounted) setState(() => _message = 'Code submitted.');
      unawaited(_poll());
    } catch (e) {
      if (mounted) setState(() => _error = 'Verification failed: $e');
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  Future<void> _disconnect() async {
    _timer?.cancel();
    try {
      await _api.disconnect();
      await SideLoaderBackground.instance.cancel();
      if (!mounted) return;
      setState(() {
        _connected = false;
        _state = null;
        _inventory = null;
        _sources = [];
        _pending = null;
        _job = null;
        _message = '';
        _error = '';
        _password.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Disconnect failed: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _api.close();
    _server.dispose();
    _user.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('SideLoader'), actions: [
      if (_connected) IconButton(
        tooltip: 'Refresh',
        onPressed: _busy ? null : _refresh,
        icon: const Icon(Icons.refresh)),
    ]),
    body: _initializing
      ? const Center(child: CircularProgressIndicator())
      : _connected ? _dashboard() : _login(),
  );

  Widget _problemCard(SideLoaderProblem problem) {
    final color = problem.isError ? Colors.red : Colors.orange;
    return Container(
      key: const ValueKey('sideloader-device-problem'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${problem.isError ? 'ERROR' : 'WARNING'}: ${problem.title}',
            style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (var i = 0; i < problem.steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SelectableText('${i + 1}. ${problem.steps[i]}'),
          ),
      ]),
    );
  }

  Widget _alerts() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    if (_error.isNotEmpty) Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(_error, style: const TextStyle(color: Colors.red))),
    if (_message.isNotEmpty) Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(_message, style: const TextStyle(color: Colors.green))),
  ]);

  // AutofillGroup + hints let iOS offer the saved SideLoader login from
  // Passwords instead of hand-typing the generated 24-character password.
  Widget _login() => AutofillGroup(child: ListView(
      padding: const EdgeInsets.all(18), children: [
    const Text('Connect your self-hosted SideLoader server.'),
    const SizedBox(height: 18),
    TextField(
      controller: _server,
      onChanged: (_) => setState(() {}),
      keyboardType: TextInputType.url,
      autocorrect: false,
      textCapitalization: TextCapitalization.none,
      decoration: const InputDecoration(
        labelText: 'Server URL', hintText: 'http://Your-Mac-Name.local:38080',
        border: OutlineInputBorder())),
    const SizedBox(height: 12),
    TextField(
      controller: _user,
      onChanged: (_) => setState(() {}),
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      textCapitalization: TextCapitalization.none,
      autofillHints: const [AutofillHints.username],
      decoration: const InputDecoration(
        labelText: 'SideLoader username', border: OutlineInputBorder())),
    const SizedBox(height: 12),
    TextField(
      controller: _password,
      onChanged: (_) => setState(() {}),
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: const [AutofillHints.password],
      decoration: const InputDecoration(
        labelText: 'SideLoader password', border: OutlineInputBorder())),
    SwitchListTile(
      title: const Text('Remember securely'),
      subtitle: const Text('Uses system secure storage'),
      value: _remember,
      onChanged: _busy ? null : (v) => setState(() => _remember = v)),
    _alerts(),
    FilledButton(
      onPressed: _busy || _server.text.trim().isEmpty ||
          _user.text.trim().isEmpty || _password.text.isEmpty
          ? null : _connect,
      child: Text(_busy ? 'Connecting…' : 'Connect')),
    const SizedBox(height: 14),
    const Text('Use a trusted LAN, private VPN, or HTTPS address. '
        'This is an API connection; it does not create an iPhone tunnel.',
        style: TextStyle(fontSize: 12)),
  ]));

  Widget _dashboard() => RefreshIndicator(
    onRefresh: _refresh,
    child: ListView(padding: const EdgeInsets.all(14), children: [
      _alerts(),
      if (_busy) const LinearProgressIndicator(),
      Card(child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.dns_outlined),
            const SizedBox(width: 8),
            const Expanded(child: Text('SideLoader server',
                style: TextStyle(fontWeight: FontWeight.bold))),
            TextButton(onPressed: _busy ? null : _disconnect,
                child: const Text('Disconnect')),
          ]),
          Text(_server.text, overflow: TextOverflow.ellipsis),
          if ((_state?.devices.length ?? 0) > 0)
            DropdownButtonFormField<String>(
              key: ValueKey(_deviceId),
              initialValue: _deviceId,
              decoration: const InputDecoration(labelText: 'iPhone'),
              items: _state!.devices.map((d) =>
                  DropdownMenuItem(value: d.udid, child: Text(d.name))).toList(),
              onChanged: _busy ? null : (id) {
                if (id != null && id != _deviceId) {
                  setState(() { _deviceId = id; _inventory = null; _pending = null; });
                  unawaited(_api.saveDevice(id));
                  unawaited(_refresh());
                }
              }),
          const SizedBox(height: 8),
          Row(children: [
            Icon(_device?.reachable == true
                ? Icons.check_circle_outline : Icons.info_outline,
                color: _device?.reachable == true ? Colors.green : Colors.orange),
            const SizedBox(width: 8),
            Expanded(child: Text(_device == null ? 'No registered iPhone' :
                _device!.reachable ? 'iPhone reachable from server' :
                'iPhone offline or connection unverified')),
          ]),
          if (_device?.problem != null) _problemCard(_device!.problem!),
          if (_scanError.isNotEmpty && _device?.problem == null)
            Text(_scanError, style: const TextStyle(color: Colors.orange)),
          if (_sourcesError.isNotEmpty)
            Text(_sourcesError, style: const TextStyle(color: Colors.orange)),
        ]),
      )),
      if (_state?.blocked == true)
        Card(child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text("Apple signing paused. ${_state?.blockedReason ?? ''}. "
              'Resolve it on the SideLoader dashboard.',
              style: const TextStyle(color: Colors.red)),
        )),
      if (_pending != null) _confirmation(_pending!),
      if (_job != null) _jobPanel(_job!),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Row(children: [
          const Expanded(child: Text('Installed apps',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
          TextButton.icon(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.sync),
            label: const Text('Check updates')),
        ]),
      ),
      if (_apps.isEmpty)
        const Card(child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('No confirmed SideLoader-managed apps. '
              'Connect and scan the iPhone using SideLoader.'),
        )),
      for (final app in _apps) _appPanel(app),
      const SizedBox(height: 12),
      const Text('Re-sign uses the saved IPA. Reinstall latest downloads '
          'from a saved source, regardless of version. Installation requires '
          'SideLoader to reach the iPhone.',
          style: TextStyle(fontSize: 12)),
      const SizedBox(height: 32),
    ]),
  );

  Widget _appPanel(SideLoaderApp app) {
    final target = app.targetFor(_deviceId);
    final source = sideLoaderLatestSource(_sources, app.bundleId);
    final installedVersion = _inventory?.where((item) => item.matches(app.bundleId))
        .map((item) => item.version).firstOrNull;
    final newer = source != null && sideLoaderNewerVersion(
        source.version, installedVersion ?? app.version);
    return Card(child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(app.name,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17))),
          Text(target?.remaining(_state?.now ?? 0) ?? 'Expiry unknown',
              style: const TextStyle(fontSize: 12)),
        ]),
        const SizedBox(height: 4),
        Text('${app.version} · ${app.bundleId}',
            style: Theme.of(context).textTheme.bodySmall),
        Text(_inventory == null ? 'Device installation unverified' :
            _installed(app) ? 'Installed on iPhone' : 'Not installed',
            style: TextStyle(color: _installed(app) ? Colors.green : Colors.orange)),
        if (newer) Text('New version available: ${source.version}',
            style: const TextStyle(color: Colors.green)),
        const SizedBox(height: 7),
        Wrap(spacing: 8, runSpacing: 6, children: [
          OutlinedButton(
            onPressed: _canSign(app) ? () => _choose(app, false) : null,
            child: const Text('Re-sign')),
          OutlinedButton(
            onPressed: _canSign(app) && source != null ?
                () => _choose(app, true) : null,
            child: const Text('Reinstall latest')),
        ]),
      ]),
    ));
  }

  Widget _confirmation(_Action action) => Card(child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(action.source != null ? 'Confirm Reinstall latest' : 'Confirm Re-sign',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      Text(action.app.name),
      const SizedBox(height: 8),
      Text(action.source == null
          ? 'Sign the saved IPA and reinstall it on this iPhone.'
          : 'Download the latest IPA from ${action.source!.sourceName} '
              '(same version is allowed), preserve the previous saved IPA, '
              'then sign and install it.'),
      const SizedBox(height: 6),
      const Text('Apple may request a six-digit verification code. '
          'Failed signing is not automatically retried.'),
      const SizedBox(height: 12),
      Wrap(spacing: 8, children: [
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: Text(_busy ? 'Preparing…' : 'Confirm')),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _pending = null),
          child: const Text('Cancel')),
      ]),
    ]),
  ));

  Widget _jobPanel(SideLoaderJob job) => Card(child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_activeApp.isEmpty ? 'Signing job' : _activeApp,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
      Text(job.running ? (job.stage.isEmpty ? 'Signing…' : job.stage)
          : job.rc == 0 ? 'Installation completed' : 'Installation failed'),
      const SizedBox(height: 8),
      if (job.running) ...[
        job.fraction != null && job.fraction! > 0
            ? LinearProgressIndicator(value: job.fraction!.clamp(0.0, 1.0))
            : const LinearProgressIndicator(),
        if (job.delivery == 'reported_sent')
          const Text('Apple reports sending a verification code.'),
        if (job.needsInput && job.acceptsInput) ...[
          Text(job.secondsLeft == null
              ? 'Enter the six-digit Apple verification code'
              : 'Enter the six-digit Apple verification code '
                  '(${job.secondsLeft}s remaining)'),
          TextField(
            controller: _code,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Verification code')),
          FilledButton(
            onPressed: _sendingCode ||
                !RegExp(r'^[0-9]{6}$').hasMatch(_code.text.trim())
                ? null : _verify,
            child: Text(_sendingCode ? 'Submitting…' : 'Verify')),
        ],
        TextButton(
          onPressed: () async {
            try {
              await _api.cancelJob();
              await _poll();
            } catch (e) {
              if (mounted) setState(() => _error = 'Cancel failed: $e');
            }
          }, child: const Text('Cancel signing attempt')),
      ] else
        TextButton(
          onPressed: () => setState(() { _job = null; _activeApp = ''; }),
          child: const Text('Dismiss')),
      if (job.last.isNotEmpty) Text(job.last,
          style: Theme.of(context).textTheme.bodySmall),
    ]),
  ));
}

class _Action {
  const _Action(this.app, this.source);
  final SideLoaderApp app;
  final SideLoaderSourceApp? source;
}

List<int>? _versionParts(String value) {
  if (!RegExp(r'^[0-9]+(\.[0-9]+)*$').hasMatch(value)) return null;
  return value.split('.').map(int.parse).toList();
}

bool sideLoaderNewerVersion(String candidate, String current) {
  final a = _versionParts(candidate), b = _versionParts(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < a.length || i < b.length; i++) {
    final left = i < a.length ? a[i] : 0;
    final right = i < b.length ? b[i] : 0;
    if (left != right) return left > right;
  }
  return false;
}

SideLoaderSourceApp? sideLoaderLatestSource(
    List<SideLoaderSourceApp> sources, String bundleId) {
  SideLoaderSourceApp? latest;
  for (final source in sources) {
    if (source.bundleId != bundleId) continue;
    if (latest == null || sideLoaderNewerVersion(
        source.version, latest.version)) {
      latest = source;
    }
  }
  return latest;
}
