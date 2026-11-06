import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'luma_nvr_client.dart';

/// Local Luma recorder: configuration, snapshots and direct live viewing.
class LumaCamerasScreen extends StatefulWidget {
  const LumaCamerasScreen({super.key, this.settingsOnly = false,
    this.store});
  final bool settingsOnly;
  final LumaSecureStore? store;

  @override
  State<LumaCamerasScreen> createState() => _LumaCamerasScreenState();
}

class _LumaCamerasScreenState extends State<LumaCamerasScreen>
    with WidgetsBindingObserver {
  late final LumaSecureStore _store = widget.store ?? LumaSecureStore();
  final _host = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  LumaNvrSettings? _saved;
  LumaNvrClient? _client;
  LumaDeviceInfo? _device;
  List<LumaCamera> _cameras = [];
  Map<int, Uint8List> _snapshots = {};
  Map<String, String> _network = {};
  Timer? _refreshTimer;
  bool _loading = true;
  bool _working = false;
  bool _refreshing = false;
  bool _editing = false;
  bool _showPassword = false;
  LumaConnectionMode _mode = LumaConnectionMode.httpsIsapi;
  bool _statusSuccess = false;
  bool _foreground = true;
  bool _viewerOpen = false;
  String? _error;
  DateTime? _lastChecked;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restore());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && !_viewerOpen && _client != null) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _client?.close();
    _host.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final config = await _store.load();
      if (!mounted) return;
      if (config != null) {
        _host.text = config.address;
        _username.text = config.username;
        _mode = config.mode;
      }
      setState(() {
        _saved = config;
        _editing = config == null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _editing = true;
        _loading = false;
        _error = 'Unable to read saved NVR credentials.';
      });
    }
  }

  void _startRefreshing() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (_foreground && !_viewerOpen && !_working && !_refreshing) {
        unawaited(_refreshSnapshots());
      }
    });
  }

  LumaNvrSettings _entered() {
    final previous = _saved;
    final address = _host.text.trim();
    final username = _username.text.trim();
    return LumaNvrSettings.fromInput(
      address, username,
      _password.text.isNotEmpty ? _password.text
          : previous?.password ?? '',
      mode: _mode,
    );
  }

  /// Secure save is entirely offline: no login or port probe is required.
  Future<void> _saveSettings() async {
    if (_working) return;
    setState(() { _working = true; _error = null; });
    try {
      final config = _entered();
      await _store.save(config);
      if (!mounted) return;
      _refreshTimer?.cancel();
      _client?.close();
      _client = null;
      _host.text = config.address;
      _username.text = config.username;
      _password.clear();
      setState(() {
        _saved = config;
        _device = null;
        _cameras = [];
        _snapshots = {};
        _network = {};
        _lastChecked = null;
        _editing = false;
        _statusSuccess = true;
        _error = 'Saved securely. Connect whenever you are ready.';
      });
    } on LumaNvrException catch (error) {
      if (mounted) {
        setState(() { _error = error.message; _statusSuccess = false; });
      }
    } catch (_) {
      if (mounted) setState(() {
        _error = 'Unable to save Luma settings to secure storage.';
        _statusSuccess = false;
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Explicit connection using previously saved settings, never modifying them.
  Future<void> _connect() async {
    if (_working || _saved == null) return;
    setState(() { _working = true; _error = null; });
    LumaNvrClient? candidate;
    try {
      final config = _saved!;
      candidate = LumaNvrClient(config);
      if (config.mode == LumaConnectionMode.sdkServer) {
        final reachable = await candidate.sdkPortReachable();
        if (!mounted) return;
        setState(() {
          _statusSuccess = false;
          _error = reachable
              ? 'SDK/Server port is reachable. This does not verify NVR '
                  'login or enable cameras; native SDK support is required.'
              : 'SDK/Server port is not reachable. Verify the forwarded port '
                  'and NVR network connection.';
        });
        return;
      }
      final info = await candidate.deviceInfo();
      if (!mounted) return;
      _client?.close();
      _client = candidate;
      candidate = null;
      _password.clear();
      setState(() {
        _device = info;
        _editing = false;
        _statusSuccess = true;
        _error = 'Connected to ${info.name}.';
        _cameras = [];
        _snapshots = {};
      });
      _startRefreshing();
      await _refresh();
    } on LumaNvrException catch (error) {
      var message = error.message;
      if (candidate != null &&
          (message.contains('8 seconds') ||
           message.contains('TLS handshake') ||
           message.contains('Cannot reach the NVR'))) {
        message = await candidate.diagnoseFailedConnection();
      }
      if (mounted) {
        setState(() { _error = message; _statusSuccess = false; });
      }
    } catch (_) {
      if (mounted) setState(() {
        _error = 'Could not connect to the Luma NVR.';
        _statusSuccess = false;
      });
    } finally {
      candidate?.close();
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _disconnect() async {
    if (_working) return;
    setState(() { _working = true; _error = null; });
    try {
      await _store.remove();
      _refreshTimer?.cancel();
      _client?.close();
      _client = null;
      if (!mounted) return;
      _host.clear();
      _username.clear();
      _password.clear();
      setState(() {
        _saved = null;
        _device = null;
        _cameras = [];
        _snapshots = {};
        _network = {};
        _editing = true;
        _mode = LumaConnectionMode.httpsIsapi;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not remove saved NVR settings.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _refresh() async {
    final client = _client;
    if (client == null || _refreshing || !_foreground || _viewerOpen) {
      return;
    }
    setState(() { _refreshing = true; });
    try {
      final device = await client.deviceInfo();
      final cameras = await client.cameras();
      Map<String, String> network = {};
      try {
        network = await client.network();
      } catch (_) {
        // Some Luma firmwares do not expose interface details.
      }
      if (!mounted || !identical(client, _client)) return;
      setState(() {
        _device = device;
        _cameras = cameras;
        _network = network;
        _lastChecked = DateTime.now();
        _snapshots.removeWhere((id, _) =>
            !cameras.any((camera) => camera.channel == id));
      });
      await _refreshSnapshots();
    } on LumaNvrException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Unable to load cameras.');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _refreshSnapshots() async {
    final client = _client;
    if (client == null || !_foreground || _viewerOpen) return;
    final cameras = _cameras.where((camera) => camera.online != false)
        .toList();
    // Limit concurrent NVR camera requests to avoid overloading the recorder.
    for (var offset = 0; offset < cameras.length; offset += 4) {
      if (!mounted || !_foreground || _viewerOpen ||
          !identical(_client, client)) {
        return;
      }
      final group = cameras.skip(offset).take(4);
      await Future.wait(group.map((camera) async {
        try {
          final bytes = await client.snapshot(camera.channel);
          if (mounted && identical(_client, client) && !_viewerOpen) {
            setState(() => _snapshots[camera.channel] = bytes);
          }
        } catch (_) {
          if (mounted && identical(_client, client)) {
            setState(() => _snapshots.remove(camera.channel));
          }
        }
      }));
    }
  }

  Future<void> _openCamera(LumaCamera camera) async {
    final config = _saved;
    if (config == null || camera.online == false) return;
    setState(() => _viewerOpen = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => LumaLiveViewScreen(
          settings: config,
          camera: camera,
        ),
      ));
    } finally {
      if (mounted) {
        setState(() => _viewerOpen = false);
        unawaited(_refreshSnapshots());
      }
    }
  }

  Widget _configuration() {
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Luma NVR connection',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('luma-host'),
            controller: _host,
            enabled: !_working,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'NVR address and port',
              hintText: '192.168.1.79:443 or host:58000',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('luma-username'),
            controller: _username,
            enabled: !_working,
            autocorrect: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(), labelText: 'Username'),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('luma-password'),
            controller: _password,
            enabled: !_working,
            obscureText: !_showPassword,
            autocorrect: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: _saved == null ? 'Password'
                  : 'Password (leave blank to keep saved)',
              suffixIcon: IconButton(
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                onPressed: () => setState(
                    () => _showPassword = !_showPassword),
                icon: Icon(_showPassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('Connection type',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          SegmentedButton<LumaConnectionMode>(
            segments: const [
              ButtonSegment(value: LumaConnectionMode.httpsIsapi,
                  label: Text('HTTPS / ISAPI')),
              ButtonSegment(value: LumaConnectionMode.sdkServer,
                  label: Text('Server / SDK')),
            ],
            selected: {_mode},
            onSelectionChanged: _working ? null
                : (selection) => setState(() => _mode = selection.first),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 8, children: [
            OutlinedButton.icon(
              key: const ValueKey('luma-save-connection'),
              onPressed: _working ? null : () =>
                  unawaited(_saveSettings()),
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save'),
            ),
            if (_saved != null)
              TextButton(
                onPressed: _working ? null
                    : () => setState(() => _editing = false),
                child: const Text('Cancel'),
              ),
          ]),
          if (_saved != null)
            Align(alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('luma-remove-connection'),
                onPressed: _working ? null : () => unawaited(_disconnect()),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove saved connection'),
              ),
            ),
          const SizedBox(height: 10),
          Text(
            _mode == LumaConnectionMode.sdkServer
                ? 'Server / SDK: enter the external forwarded port (for '
                    'example 58000 → recorder 8000). The port check does '
                    'not authenticate or enable cameras without a native SDK.'
                : 'HTTPS / ISAPI: enter the recorder web HTTPS port, '
                    'usually 443. This is different from its SDK/Server port.',
            key: const ValueKey('luma-isapi-port-help'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Text('Save stores settings securely even while offline. '
              'Connect is a separate action.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ));
  }

  Widget _savedConnection() {
    final config = _saved!;
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Saved NVR', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(config.address, key: const ValueKey('luma-saved-address')),
          Text(config.mode == LumaConnectionMode.sdkServer
              ? 'Server / SDK' : 'HTTPS / ISAPI',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 10),
          if (_device == null)
            FilledButton.icon(
              key: const ValueKey('luma-connect'),
              onPressed: _working ? null : () => unawaited(_connect()),
              icon: const Icon(Icons.link_outlined),
              label: const Text('Connect'),
            )
          else
            Row(children: [
              const Icon(Icons.check_circle_outline, color: Colors.green),
              const SizedBox(width: 6),
              const Text('Connected'),
              const Spacer(),
              TextButton(
                key: const ValueKey('luma-reconnect'),
                onPressed: _working ? null : () => unawaited(_connect()),
                child: const Text('Reconnect'),
              ),
            ]),
        ],
      ),
    ));
  }

  Widget _recorder() {
    final info = _device;
    if (info == null) return const SizedBox.shrink();
    final detail = [
      if (info.model.isNotEmpty) info.model,
      if (info.firmware.isNotEmpty) 'Firmware ${info.firmware}',
      if (_saved != null) _saved!.address,
    ].join(' · ');
    return Card(
      child: Padding(padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.video_camera_back_outlined, size: 25),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(info.name, style: Theme.of(context).textTheme.titleMedium),
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
                ],
              )),
              IconButton(
                key: const ValueKey('luma-recorder-settings'),
                tooltip: 'Recorder settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) =>
                      LumaRecorderSettingsScreen(
                          client: _client!, initialInfo: info))),
                icon: const Icon(Icons.settings_outlined),
              ),
            ]),
            if (info.serial.isNotEmpty)
              Text('Serial: ${info.serial}',
                  style: Theme.of(context).textTheme.bodySmall),
            if (_network['ipAddress']?.isNotEmpty ?? false)
              Text('LAN: ${_network['ipAddress']}',
                  style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _cameraCard(LumaCamera camera) {
    final image = _snapshots[camera.channel];
    final online = camera.online;
    final scheme = Theme.of(context).colorScheme;
    return Card(clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero, child: InkWell(
        key: ValueKey('luma-camera-${camera.channel}'),
        onTap: online == false ? null : () => unawaited(_openCamera(camera)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(aspectRatio: 16 / 9,
              child: ColoredBox(color: scheme.surfaceContainer,
                child: Stack(fit: StackFit.expand, children: [
                  if (image != null)
                    Image.memory(image, fit: BoxFit.cover,
                        gaplessPlayback: true, errorBuilder:
                            (context, error, stack) =>
                                const Center(child: Icon(Icons.videocam_off)))
                  else
                    const Center(child: Icon(
                        Icons.photo_camera_back_outlined, size: 34)),
                  if (online != false)
                    const Positioned(right: 8, bottom: 6,
                      child: Icon(Icons.play_circle_fill,
                          color: Colors.white, size: 29)),
                ]),
              ),
            ),
            Padding(padding: const EdgeInsets.symmetric(
                horizontal: 9, vertical: 7),
              child: Row(children: [
                Icon(Icons.circle, size: 9, color: online == true
                    ? Colors.green : online == false
                        ? scheme.error : scheme.outline),
                const SizedBox(width: 5),
                Expanded(child: Text(camera.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600,
                        fontSize: 12))),
                Text('${camera.channel}',
                    style: Theme.of(context).textTheme.labelSmall),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Luma Cameras'),
        actions: [
          if (_saved != null && !_editing)
            IconButton(
              key: const ValueKey('luma-edit-connection'),
              tooltip: 'Connection settings',
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(Icons.tune_outlined),
            ),
          if (_saved != null && !widget.settingsOnly)
            IconButton(
              key: const ValueKey('luma-refresh'),
              tooltip: 'Refresh cameras',
              onPressed: _refreshing ? null : () => unawaited(_refresh()),
              icon: const Icon(Icons.refresh_outlined),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(14),
              children: [
                if (_editing || _saved == null) _configuration(),
                if (_saved != null && !_editing) _savedConnection(),
                if (_error != null)
                  Padding(padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_error!,
                      key: const ValueKey('luma-status'),
                      style: TextStyle(color: _statusSuccess
                              ? scheme.primary : scheme.error))),
                if (_working || _refreshing)
                  const LinearProgressIndicator(),
                if (_device != null && _client != null && !widget.settingsOnly) ...[
                  _recorder(),
                  const SizedBox(height: 10),
                  Row(children: [
                    Text('Cameras', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(width: 8),
                    Text('${_cameras.length}',
                        style: Theme.of(context).textTheme.labelLarge),
                    const Spacer(),
                    if (_lastChecked != null)
                      Text('Updated ${TimeOfDay.fromDateTime(_lastChecked!).format(context)}',
                          style: Theme.of(context).textTheme.bodySmall),
                  ]),
                  const SizedBox(height: 10),
                  if (_cameras.isEmpty && !_refreshing)
                    const Padding(padding: EdgeInsets.all(14),
                      child: Text('No cameras found. Check the NVR connection.')),
                  LayoutBuilder(builder: (context, constraints) {
                    final columns = constraints.maxWidth > 620 ? 3 : 2;
                    final width = (constraints.maxWidth -
                        (columns - 1) * 9) / columns;
                    final height = width * 9 / 16 + 44;
                    return Wrap(spacing: 9, runSpacing: 9,
                      children: [
                        for (final camera in _cameras)
                          SizedBox(width: width, height: height,
                              child: _cameraCard(camera)),
                      ],
                    );
                  }),
                ],
              ],
            ),
    );
  }
}

/// Uses a dedicated live socket. Closing this page closes/cancels the socket.
class LumaLiveViewScreen extends StatefulWidget {
  const LumaLiveViewScreen({
    super.key, required this.settings, required this.camera,
  });
  final LumaNvrSettings settings;
  final LumaCamera camera;

  @override
  State<LumaLiveViewScreen> createState() => _LumaLiveViewScreenState();
}

class _LumaLiveViewScreenState extends State<LumaLiveViewScreen> {
  LumaNvrClient? _client;
  StreamSubscription<List<int>>? _subscription;
  Uint8List? _frame;
  List<int> _partial = [];
  bool _insideJpeg = false;
  int _previousByte = -1;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    final client = LumaNvrClient(widget.settings);
    _client = client;
    try {
      final response = await client.live(widget.camera.channel);
      if (!mounted) {
        client.close();
        return;
      }
      _subscription = response.listen(_readChunk,
        onError: (Object _) {
          if (mounted) {
            setState(() => _error = 'Camera stream interrupted.');
          }
        },
        onDone: () {
          if (mounted) setState(() => _error = 'Camera stream ended.');
        },
        cancelOnError: true,
      );
    } on LumaNvrException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Unable to open live camera.');
    }
  }

  void _readChunk(List<int> bytes) {
    // MJPEG multipart headers are ignored: only bounded JPEG SOI/EOI pairs
    // are decoded. This also works if marker bytes span network chunks.
    for (final value in bytes) {
      if (!_insideJpeg) {
        if (_previousByte == 0xff && value == 0xd8) {
          _insideJpeg = true;
          _partial = [0xff, 0xd8];
        }
      } else {
        _partial.add(value);
        if (_partial.length > LumaNvrClient.maxImageBytes) {
          _insideJpeg = false;
          _partial = [];
        } else if (_previousByte == 0xff && value == 0xd9) {
          final now = DateTime.now();
          if (mounted && now.difference(_lastFrame) >=
              const Duration(milliseconds: 150)) {
            _lastFrame = now;
            setState(() {
              _frame = Uint8List.fromList(_partial);
              _error = null;
            });
          }
          _insideJpeg = false;
          _partial = [];
        }
      }
      _previousByte = value;
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: Text(widget.camera.name),
      foregroundColor: Colors.white,
      backgroundColor: Colors.black,
    ),
    body: Center(child: _frame == null
        ? Column(mainAxisSize: MainAxisSize.min, children: [
            if (_error == null)
              const CircularProgressIndicator()
            else
              const Icon(Icons.videocam_off_outlined,
                  color: Colors.white, size: 40),
            const SizedBox(height: 12),
            Text(_error ?? 'Connecting to live camera…',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white)),
          ])
        : Stack(fit: StackFit.expand, children: [
            Image.memory(_frame!, fit: BoxFit.contain,
                gaplessPlayback: true),
            if (_error != null)
              Align(alignment: Alignment.bottomCenter,
                child: Padding(padding: const EdgeInsets.all(12),
                  child: Text(_error!,
                    style: const TextStyle(color: Colors.white))),
              ),
          ])),
  );
}

/// Local owner-only recorder settings. No server endpoints or admin tokens.
class LumaRecorderSettingsScreen extends StatefulWidget {
  const LumaRecorderSettingsScreen({
    super.key, required this.client, required this.initialInfo,
  });
  final LumaNvrClient client;
  final LumaDeviceInfo initialInfo;

  @override
  State<LumaRecorderSettingsScreen> createState() =>
      _LumaRecorderSettingsScreenState();
}

class _LumaRecorderSettingsScreenState
    extends State<LumaRecorderSettingsScreen> {
  final _name = TextEditingController();
  final _time = TextEditingController();
  final _zone = TextEditingController();
  final _ntpHost = TextEditingController();
  final _ntpPort = TextEditingController(text: '123');
  final _ntpInterval = TextEditingController(text: '60');
  bool _loading = true;
  bool _working = false;
  String _mode = 'NTP';
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _name.text = widget.initialInfo.name;
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final time = await widget.client.systemTime();
      Map<String, String> ntp = {};
      try {
        ntp = await widget.client.ntp();
      } catch (_) {}
      if (!mounted) return;
      _mode = time['timeMode'] == 'manual' ? 'manual' : 'NTP';
      _time.text = time['localTime'] ?? '';
      _zone.text = time['timeZone'] ?? 'CST-8:0:0';
      _ntpHost.text = ntp['hostName'] ?? '';
      _ntpPort.text = ntp['portNo'] ?? '123';
      _ntpInterval.text = ntp['synchronizeInterval'] ?? '60';
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'This recorder did not provide time settings.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(
      Future<void> Function() update, String success) async {
    if (_working) return;
    setState(() { _working = true; _error = null; _notice = null; });
    try {
      await update();
      if (mounted) setState(() => _notice = success);
    } on LumaNvrException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'NVR rejected the change.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _name, _time, _zone, _ntpHost, _ntpPort, _ntpInterval,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _field(TextEditingController controller, String label) =>
      Padding(padding: const EdgeInsets.only(bottom: 10),
        child: TextField(controller: controller,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder())));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Recorder settings')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(padding: const EdgeInsets.all(16), children: [
            if (_error != null)
              Text(_error!, style: TextStyle(
                  color: Theme.of(context).colorScheme.error)),
            if (_notice != null)
              Text(_notice!, style: TextStyle(
                  color: Theme.of(context).colorScheme.primary)),
            if (_working) const LinearProgressIndicator(),
            Text('Recorder', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _field(_name, 'Recorder name (1–32 characters)'),
            FilledButton(
              key: const ValueKey('luma-rename-recorder'),
              onPressed: _working ? null : () => unawaited(
                _save(() => widget.client.rename(_name.text),
                    'Recorder renamed.')),
              child: const Text('Save recorder name')),
            const Divider(height: 35),
            Text('Time', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'NTP', label: Text('NTP')),
                ButtonSegment(value: 'manual', label: Text('Manual')),
              ],
              selected: {_mode},
              onSelectionChanged: (value) =>
                  setState(() => _mode = value.first),
            ),
            const SizedBox(height: 12),
            _field(_zone, 'Time zone (NVR format)'),
            if (_mode == 'manual')
              _field(_time, 'Local time (YYYY-MM-DDTHH:mm:ss)'),
            FilledButton(
              key: const ValueKey('luma-save-time'),
              onPressed: _working ? null : () => unawaited(
                _save(() => widget.client.updateTime(
                    mode: _mode, localTime: _time.text,
                    timeZone: _zone.text), 'Time settings saved.')),
              child: const Text('Save time settings')),
            const Divider(height: 35),
            Text('NTP server', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _field(_ntpHost, 'NTP hostname'),
            _field(_ntpPort, 'Port (default 123)'),
            _field(_ntpInterval, 'Sync interval (minutes)'),
            FilledButton(
              key: const ValueKey('luma-save-ntp'),
              onPressed: _working ? null : () => unawaited(
                _save(() => widget.client.updateNtp(
                  hostName: _ntpHost.text,
                  port: int.tryParse(_ntpPort.text) ?? 0,
                  intervalMinutes: int.tryParse(
                      _ntpInterval.text) ?? 0), 'NTP settings saved.')),
              child: const Text('Save NTP server')),
          ]),
  );
}
