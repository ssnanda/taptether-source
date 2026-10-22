import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'computer_store.dart';
import 'lg_webos_client.dart';
import 'lg_webos_screen.dart';
import 'samsung_tv_client.dart';
import 'samsung_tv_screen.dart';
import 'tv_network_status.dart';
import 'remote_layout_settings.dart';
import 'remote_mode_bar.dart';
import 'stepped_scroll.dart';
import 'presentation_mode.dart';
import 'media_remote.dart';
import 'visual_mode.dart';
import 'visual_transport.dart';
import 'visual_surface.dart';
import 'lan_scan.dart';
import 'network_location.dart';
import 'device_recovery.dart';
import 'device_visibility.dart';
import 'clipboard_chunks.dart';
import 'appearance.dart';
import 'app_security.dart';
import 'security_settings_screen.dart';
import 'device_manager_screen.dart';
import 'discovery.dart';
import 'phone_identity.dart';
import 'qr_pairing.dart';
import 'ssh_key_screen.dart';
import 'install_agent_screen.dart';
import 'lan_scan_screen.dart';
import 'scan_report.dart';
import 'agent_update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

final RouteObserver<ModalRoute<dynamic>> _remoteRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();

void main() => runApp(const TapTetherApp());

class TapTetherApp extends StatefulWidget {
  const TapTetherApp({super.key});
  @override
  State<TapTetherApp> createState() => _TapTetherAppState();
}

class _TapTetherAppState extends State<TapTetherApp> {
  @override
  void initState() {
    super.initState();
    unawaited(AppearanceController.instance.load());
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: AppearanceController.instance,
    builder: (context, mode, _) => MaterialApp(
      title: 'TapTether',
      debugShowCheckedModeBanner: false,
      navigatorObservers: [_remoteRouteObserver],
      theme: TapTetherPalette.light(),
      darkTheme: TapTetherPalette.dark(),
      themeMode: mode,
      builder: (context, navigator) => AppLockGate(
        child: navigator ?? const SizedBox.shrink(),
      ),
      home: const RemoteScreen(),
    ),
  );
}

/// Pin the locally generated certificate. Never accept arbitrary certificates.
/// No cloud, analytics SDK, or outbound endpoint exists in this app.
class LocalAgent {
  HttpClient? _client;
  Uri? _base;
  String? _token;
  PhoneIdentity? _identity;
  String? _deviceId;
  String? _session;
  DateTime? _sessionExpires;
  bool _shutdownEnabled = false;
  bool _screenCaptureSupported = false;
  bool get screenCaptureSupported => _screenCaptureSupported;
  String? _reportedHostname;
  String? _reportedPlatform;
  String? _reportedMacAddress;
  String? get reportedMacAddress => _reportedMacAddress;
  bool get shutdownEnabled => _shutdownEnabled;
  String? get reportedHostname => _reportedHostname;
  String? get reportedPlatform => _reportedPlatform;

  bool get configured => _base != null && _client != null;

  void configure(String host, String token, String fingerprint, {
    PhoneIdentity? identity, String? deviceId,
  }) {
    host = host.trim();
    final expected = fingerprint.replaceAll(RegExp(r'[^a-fA-F0-9]'), '').toUpperCase();
    if (expected.length != 64) {
      throw const FormatException('Enter the complete 64-character TLS SHA-256 fingerprint.');
    }
    if (token.trim().length < 20 && (identity == null || deviceId == null)) {
      throw const FormatException('Enter the pairing token printed by the agent.');
    }
    if (!_isLocalHost(host)) {
      throw const FormatException('Only RFC1918 private IPv4 or .local hosts are allowed.');
    }
    _client?.close(force: true);
    final context = SecurityContext(withTrustedRoots: false);
    final client = HttpClient(context: context);
    client.connectionTimeout = const Duration(seconds: 4);
    client.badCertificateCallback = (cert, _, __) {
      try {
        final b64 = cert.pem
            .replaceAll('-----BEGIN CERTIFICATE-----', '')
            .replaceAll('-----END CERTIFICATE-----', '')
            .replaceAll(RegExp(r'\s+'), '');
        final digest = sha256.convert(base64Decode(b64)).toString().toUpperCase();
        return digest == expected;
      } catch (_) {
        return false;
      }
    };
    _client = client;
    _base = Uri(scheme: 'https', host: host, port: 48321);
    _token = token.trim();
    _identity = identity;
    _deviceId = deviceId;
    _session = null;
    _sessionExpires = null;
    _reportedHostname = null;
    _reportedPlatform = null;
    _reportedMacAddress = null;
    _shutdownEnabled = false;
    _screenCaptureSupported = false;
  }

  static bool _isLocalHost(String host) {
    if (RegExp(r'^[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.local$').hasMatch(host)) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final oct = parts.map(int.tryParse).toList();
    if (oct.any((v) => v == null || v < 0 || v > 255)) return false;
    final a = oct[0]!, b = oct[1]!;
    return a == 10 || (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) || a == 127;
  }

  Future<Map<String, dynamic>> _postJson(
      String endpoint, Map<String, Object> body, String bearer) async {
    if (!configured) throw StateError('Agent is not configured.');
    final request = await _client!.postUrl(_base!.resolve(endpoint));
    request.headers.contentType = ContentType.json;
    if (bearer.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 6));
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) {
      throw StateError('Agent $endpoint: HTTP ${response.statusCode}');
    }
    final result = jsonDecode(text);
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Unexpected agent authentication response.');
    }
    return result;
  }

  Future<String> enrollPhone(PhoneIdentity phone, String name) async {
    if ((_token ?? '').length < 20) {
      throw StateError('Owner pairing token is required for enrollment.');
    }
    final result = await _postJson('/api/pair', {
      'name': name,
      'publicKey': phone.encodedPublicKey,
    }, _token!);
    final id = result['id'];
    if (id is! String || id != phone.id) {
      throw StateError('Agent device identity does not match this phone.');
    }
    return id;
  }

  Future<String> _bearer() async {
    final identity = _identity;
    final id = _deviceId;
    if (identity == null || id == null) return _token ?? '';
    final cached = _session;
    if (cached != null && _sessionExpires != null &&
        _sessionExpires!.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return cached;
    }
    final challenge = await _postJson('/api/auth/challenge', {'id': id}, '');
    final nonce = challenge['nonce'];
    if (nonce is! String || nonce.length < 32) {
      throw const FormatException('Agent challenge is invalid.');
    }
    final signature = await identity.signChallenge(nonce);
    final response = await _postJson('/api/auth/session', {
      'id': id, 'nonce': nonce, 'signature': signature,
    }, '');
    final token = response['token'];
    if (token is! String || token.length < 32) {
      throw const FormatException('Agent session invalid.');
    }
    _session = token;
    _sessionExpires = DateTime.now().add(const Duration(minutes: 14));
    return token;
  }

  void usePhoneKey(PhoneIdentity identity, String id) {
    _identity = identity;
    _deviceId = id;
    _token = null;
    _session = null;
    _sessionExpires = null;
  }

  Future<void> send(String type, [Map<String, Object> details = const {}]) async {
    if (!configured) throw StateError('Connect to your local agent first.');
    final req = await _client!.postUrl(_base!.resolve('/api/control'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'type': type, ...details}));
    final res = await req.close().timeout(const Duration(seconds: 5));
    if (res.statusCode != 204) {
      final body = await utf8.decoder.bind(res).join();
      throw StateError('Agent response ${res.statusCode}: $body');
    }
    await res.drain<void>();
  }

  Future<String?> agentVersion() async {
    if (!configured) return null;
    try {
      final request = await _client!.getUrl(_base!.resolve('/api/info'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
      final response = await request.close().timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = jsonDecode(await utf8.decoder.bind(response).join());
      if (body is Map && body['version'] is String) {
        _shutdownEnabled = body['shutdownEnabled'] == true;
        _screenCaptureSupported = body['screenCaptureSupported'] == true;
        final name = body['hostname'];
        if (name is String &&
            RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$').hasMatch(name)) {
          _reportedHostname = name;
        }
        final macAddress = body['macAddress'];
        if (macAddress is String &&
            RegExp(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(macAddress)) {
          _reportedMacAddress = macAddress.toUpperCase();
        }
        final platform = body['platform'];
        if (platform == 'linux' || platform == 'darwin' || platform == 'windows') {
          _reportedPlatform = platform as String;
        }
        return body['version'] as String;
      }
    } catch (_) {
      // Older agents without this endpoint remain compatible.
    }
    return null;
  }

  /// Best-effort ARP neighbor inventory from the authenticated agent.
  Future<Map<String, String>> trustedLanNeighbors() async {
    if (!configured) return {};
    try {
      final request = await _client!.getUrl(_base!.resolve('/api/neighbors'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return {};
      }
      final decoded = jsonDecode(await utf8.decoder.bind(response).join());
      if (decoded is! List || decoded.length > 1024) return {};
      final result = <String, String>{};
      for (final item in decoded) {
        if (item is! Map || item['ip'] is! String || item['mac'] is! String) {
          continue;
        }
        final ip = item['ip'] as String;
        final mac = item['mac'] as String;
        if (isPrivateIPv4(ip) &&
            RegExp(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(mac)) {
          result[ip] = mac.toUpperCase();
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  /// Existing agents that lack this endpoint still use the SSH/local updater.
    Future<bool> requestUpdate() async {
    if (!configured) throw StateError('Connect to a paired computer first.');
    final req = await _client!.postUrl(_base!.resolve('/api/update'));
    req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
    req.write(jsonEncode({'confirm': true}));
    final res = await req.close().timeout(const Duration(seconds: 8));
    final result = res.statusCode;
    await res.drain<void>();
    if (result == 202) return true;
    if (result == 404 || result == 501) return false;
    throw StateError('Computer could not start the update (HTTP $result).');
  }


  Future<void> openMedia(String service, String query, {bool focusOnly = false}) async {
    if (!configured) throw StateError('Connect to a paired computer first.');
    final req = await _client!.postUrl(_base!.resolve('/api/media/open'));
    req.headers.contentType = ContentType.json;
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
    req.write(jsonEncode({'service': service, 'query': query, 'focus': focusOnly}));
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode != 204) {
      final explanation = await utf8.decoder.bind(res).join();
      throw StateError(explanation.trim().isNotEmpty
          ? explanation.trim()
          : 'Computer could not open the media service.');
    }
    await res.drain<void>();
  }

  Future<ScreenFrame> snapshot({bool detail = false}) async {
    if (!configured) throw StateError('Connect to a paired computer first.');
    final req = await _client!.getUrl(_base!.resolve(detail ? '/api/snapshot?detail=1' : '/api/snapshot'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
    final response = await req.close().timeout(const Duration(seconds: 7));
    if (response.statusCode != 200) {
      final explanation = await utf8.decoder.bind(response).join();
      throw StateError(explanation.trim().isEmpty
          ? 'Screen capture unavailable (HTTP ${response.statusCode}).'
          : explanation.trim());
    }
    if (detail && response.headers.value('x-capture-detail') != 'native') {
      await response.drain<void>();
      throw StateError('Computer agent needs an update for high-detail Snapshot.');
    }
    final width = int.tryParse(response.headers.value('x-screen-width') ?? '');
    final height = int.tryParse(response.headers.value('x-screen-height') ?? '');
    if (width == null || height == null || width < 1 || height < 1 ||
        width > 1920 || height > 1080) {
      await response.drain<void>();
      throw const FormatException('Agent sent invalid screen dimensions.');
    }
    final output = BytesBuilder(copy: false);
    await for (final bytes in response.timeout(const Duration(seconds: 8))) {
      output.add(bytes);
      if (output.length > 4 << 20) {
        throw const FormatException('Screenshot exceeds safe transfer size.');
      }
    }
    return ScreenFrame(output.takeBytes(), width, height);
  }

  Stream<ScreenFrame> liveFrames({int fps = 15}) async* {
    if (fps != 8 && fps != 15 && fps != 30) {
      throw const FormatException('Unsupported streaming frame rate.');
    }
    if (!configured) throw StateError('Connect to a paired computer first.');
    final req = await _client!.getUrl(_base!.resolve('/api/live?fps=$fps'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${await _bearer()}');
    final response = await req.close().timeout(const Duration(seconds: 7));
    if (response.statusCode != 200) {
      final explanation = await utf8.decoder.bind(response).join();
      throw StateError(explanation.trim().isEmpty
          ? 'Live video unavailable (HTTP ${response.statusCode}).'
          : explanation.trim());
    }
    final frames = MjpegFrameDecoder();
    await for (final bytes in response) {
      for (final frame in frames.add(bytes)) {
        yield frame;
      }
    }
  }

  /// Explicit short, authenticated local-only test. Measures application
  /// throughput from THIS paired computer to the phone, not Wi-Fi PHY speed.
  /// Older agents return HTTP 404 and cannot be benchmarked remotely.
  Future<({double rttMs, double downMbps})> benchmarkLan() async {
    if (!configured) throw StateError('Connect to a paired computer first.');
    final bearer = await _bearer();
    Future<(double, int)> transfer(int bytes) async {
      final stopwatch = Stopwatch()..start();
      final uri = _base!.resolve('/api/lan-benchmark?bytes=$bytes');
      final request = await _client!.getUrl(uri)
          .timeout(const Duration(seconds: 4));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close()
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 404) {
        await response.drain<void>();
        throw StateError(
          'Computer agent needs an update for the LAN speed test.');
      }
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw StateError('LAN speed test unavailable (HTTP ${response.statusCode}).');
      }
      var received = 0;
      await for (final part in response.timeout(const Duration(seconds: 7))) {
        received += part.length;
        if (received > bytes || stopwatch.elapsed > const Duration(seconds: 10)) {
          throw const FormatException('LAN test transfer exceeded safety limits.');
        }
      }
      stopwatch.stop();
      if (received != bytes || stopwatch.elapsedMicroseconds <= 0) {
        throw const FormatException('LAN speed test received incomplete data.');
      }
      return (stopwatch.elapsedMicroseconds / 1000000, received);
    }

    final roundTrips = <double>[];
    for (var i = 0; i < 3; i++) {
      final (elapsed, _) = await transfer(0);
      roundTrips.add(elapsed * 1000);
    }
    roundTrips.sort();
    final (elapsed, bytes) = await transfer(4 << 20);
    return (
      rttMs: roundTrips[1],
      downMbps: bytes * 8 / (elapsed * 1000000),
    );
  }

  void disconnect() {
    _client?.close(force: true);
    _client = null;
    _base = null;
    _token = null;
    _identity = null;
    _deviceId = null;
    _session = null;
    _sessionExpires = null;
    _shutdownEnabled = false;
    _screenCaptureSupported = false;
    _reportedHostname = null;
    _reportedPlatform = null;
    _reportedMacAddress = null;
  }
}

class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen>
    with WidgetsBindingObserver, RouteAware {
  final agent = LocalAgent();
  final deviceStore = ComputerStore();
  final remoteLayoutStore = RemoteLayoutStore();
  final networkLocationStore = NetworkLocationStore();
  Timer? _heartbeatTimer;
  DetectedLanRange? _wifiRange;
  String? _detectedLocation;
  // Saved devices appear immediately; the user can filter by location or hide offline.
  String _locationFilter = 'all';
  bool _showOffline = true;
  bool _showQuickActions = false;
  bool _checkingHeartbeat = false;
  bool _recoveringDiscovery = false;
  bool _probingOfflineAgents = false;
  DateTime? _lastPassiveDiscovery;
  RawDatagramSocket? _announcementSocket;
  StreamSubscription<RawSocketEvent>? _announcementSubscription;
  final Map<String, DateTime> _recentAnnouncements = {};
  int _heartbeatGeneration = 0;
  String? _connectingDeviceId;
  String? _dashboardNotice;
  Future<PhoneIdentity>? _cachedPhoneIdentity;
  Future<PhoneIdentity> _phoneIdentity() =>
      _cachedPhoneIdentity ??= PhoneIdentity.loadOrCreate();
  bool _scanningToReconcile = false;
  final Set<String> _scanVerifiedDeviceIds = {};
  final ScanReport _discoveryReport = ScanReport();
  String? _lastNetworkId;
  final Map<String, bool> _online = {};
  // Installed versions verified only from authenticated saved-host agent info.
  final Map<String, String> _savedAgentVersions = {};
  RemoteLayoutSettings _remoteLayout = const RemoteLayoutSettings();
  String? _connectedPlatform;
  bool _connectionLost = false;
  bool _agentInputDenied = false;
  String? _connectionTechnical;
  bool _retryingConnection = false;
  List<SavedComputer> savedComputers = [];
  List<LgTvDevice> savedLgTvs = [];
  List<SamsungTvDevice> savedSamsungTvs = [];
  final Map<String, bool> _tvOnline = {};
  final Map<String, DateTime> _tvLastSeen = {};
  bool _checkingTvStatus = false;
  bool _recoveringTvAddresses = false;
  DateTime? _lastTvRecovery;
  List<DiscoveredDevice> nearbyComputers = [];
  bool searching = false;
  bool installingAgent = false;
  bool _showPairForm = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String? discoveredName;
  final host = TextEditingController();
  final token = TextEditingController();
  final pin = TextEditingController();
  final typing = TextEditingController();
  String status = 'Not connected';
  String installedVersion = '…';
  String? availableAppVersion;
  String? availableAgentVersion;
  String? connectedAgentVersion;
  String? _latestReleaseVersion;
  final Map<String, String> _latestAgentByPlatform = {};
  bool _macShortcuts = false;
  bool _haptics = true;
  Timer? _snapshotTimer;
  Timer? _adaptiveLiveTimer;
  int _liveFps = 15;
  bool _liveAdjusted = false;
  bool _requestDetailFrame = false;
  StreamSubscription<ScreenFrame>? _liveFrames;
  ScreenFrame? _currentFrame;
  final LiveStreamRate _liveRate = LiveStreamRate();
  String? _screenError;
  bool _screenBusy = false;
  bool _appForeground = true;
  bool _pageVisible = true;
  bool _refreshAfterCapture = false;
  int _screenEpoch = 0;
  bool _immersiveDockVisible = false;
  Timer? _immersiveDockTimer;

  void _showImmersiveDock() {
    _immersiveDockTimer?.cancel();
    if (!_immersiveDockVisible) setState(() => _immersiveDockVisible = true);
    _immersiveDockTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _immersiveDockVisible = false);
    });
  }

  void _hideImmersiveDock() {
    _immersiveDockTimer?.cancel();
    if (_immersiveDockVisible && mounted) {
      setState(() => _immersiveDockVisible = false);
    }
  }


  bool get _viewingScreen => agent.configured && !_connectionLost &&
      _appForeground && _pageVisible &&
      !_remoteLayout.mediaMode && !_remoteLayout.presentationMode &&
      agent.screenCaptureSupported &&
      VisualModePolicy.normalize(_remoteLayout.visualMode) != 'trackpad';

  void _stopScreen({bool preserveFrame = false}) {
    _liveRate.clear();
    _screenEpoch++;
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
    _adaptiveLiveTimer?.cancel();
    _adaptiveLiveTimer = null;
    final prior = _liveFrames;
    _liveFrames = null;
    if (prior != null) unawaited(prior.cancel());
    _screenBusy = false;
    _refreshAfterCapture = false;
    if (!preserveFrame) _currentFrame = null;
    _screenError = null;
  }

  void _syncScreen({bool preserveFrame = false}) {
    _stopScreen(preserveFrame: preserveFrame);
    if (!_viewingScreen) return;
    final epoch = _screenEpoch;
    if (_remoteLayout.visualMode == 'snapshot') {
      unawaited(_refreshScreenshot());
      _snapshotTimer = Timer.periodic(VisualModePolicy.snapshotInterval,
          (_) => unawaited(_refreshScreenshot()));
    } else if (_remoteLayout.visualMode == 'live') {
      _screenBusy = true;
      _liveFrames = agent.liveFrames(fps: _liveFps).listen((frame) {
        if (!mounted || _screenEpoch != epoch || !_viewingScreen) return;
        _liveRate.record(frame);
        setState(() {
          _currentFrame = frame;
          _screenBusy = false;
          _screenError = null;
        });
      }, onError: (Object error) {
        if (!mounted || _screenEpoch != epoch) return;
        setState(() {
          _screenBusy = false;
          _screenError = error.toString();
        });
      }, onDone: () {
        if (!mounted || _screenEpoch != epoch) return;
        setState(() {
          _screenBusy = false;
          _screenError ??= 'Live stream stopped. Reopen Live to retry.';
        });
      }, cancelOnError: true);
      // Conservative one-way adaptation per session. Avoid bouncing between
      // bitrates when Ubuntu's capture source is limited to 10 fps.
      _adaptiveLiveTimer = Timer(const Duration(seconds: 12), () {
        if (!mounted || _screenEpoch != epoch || !_viewingScreen) return;
        final measured = _liveRate.framesPerSecond;
        final rate = _liveRate.megabitsPerSecond;
        if (measured == null) return;
        final reduced = measured < _liveFps * 0.70 && _liveFps > 8;
        final excellent = !_liveAdjusted && _liveFps == 15 &&
            measured >= 14 && rate != null && rate < 6;
        if (reduced || excellent) {
          _liveAdjusted = true;
          _liveFps = reduced ? 8 : 30;
          _syncScreen(preserveFrame: true);
        }
      });
    }
  }

  Future<void> _refreshScreenshot() async {
    if (!_viewingScreen || _remoteLayout.visualMode != 'snapshot') return;
    if (_screenBusy) {
      _refreshAfterCapture = true;
      return;
    }
    _refreshAfterCapture = false;
    final epoch = _screenEpoch;
    _screenBusy = true;
    if (mounted) setState(() {});
    try {
      final detail = _requestDetailFrame;
      _requestDetailFrame = false;
      final frame = await agent.snapshot(detail: detail);
      if (!mounted || _screenEpoch != epoch) return;
      setState(() {
        _currentFrame = frame;
        _screenError = null;
      });
    } catch (error) {
      if (mounted && _screenEpoch == epoch) {
        setState(() => _screenError = error.toString());
      }
    } finally {
      if (mounted && _screenEpoch == epoch) {
        setState(() => _screenBusy = false);
        if (_refreshAfterCapture) {
          _refreshAfterCapture = false;
          unawaited(_refreshScreenshot());
        }
      }
    }
  }


  @override
  void initState() {
    super.initState();
    unawaited(loadInstalledVersion());
    unawaited(checkForUpdates());
    unawaited(loadComputers());
    unawaited(loadLgTvs());
    unawaited(loadSamsungTvs());
    unawaited(_listenForAgentAnnouncements());
    unawaited(_refreshNetworkLocation());
    WidgetsBinding.instance.addObserver(this);
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed) {
        unawaited(_refreshNetworkLocation());
        unawaited(_refreshHeartbeats());
        unawaited(_refreshTvStatuses());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) _remoteRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() {
    _pageVisible = false;
    _stopScreen();
  }

  @override
  void didPopNext() {
    _pageVisible = true;
    _syncScreen();
  }

  @override
  void didChangeMetrics() {
    // Reconnect Snapshot/Live when the orientation switches into or out of
    // the full-screen landscape control surface.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncScreen();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    if (_appForeground) {
      _syncScreen();
      unawaited(_refreshNetworkLocation());
      unawaited(_refreshHeartbeats());
      unawaited(_refreshTvStatuses());
    } else {
      _stopScreen();
    }
  }

  Future<void> _refreshNetworkLocation() async {
    final current = await detectLanRange();
    final label = await networkLocationStore.locationFor(current);
    final identity = networkLocationStore.identifier(current);
    if (mounted) {
      final changed = _lastNetworkId != identity;
      setState(() {
        if (changed) {
          _online.clear();
          _savedAgentVersions.clear();
          // Recovery cooldown belongs to a network, not the lifetime of the
          // phone app. Recheck promptly after a Wi-Fi/subnet change.
          _lastPassiveDiscovery = null;
          _lastTvRecovery = null;
          _tvOnline.clear();
        }
        _lastNetworkId = identity;
        _wifiRange = current;
        _detectedLocation = label;
      });
      if (changed) {
        unawaited(_refreshTvStatuses());
        if (savedLgTvs.isNotEmpty || savedSamsungTvs.isNotEmpty) {
          unawaited(_recoverTvAddresses());
        }
      }
      if (changed && savedComputers.isNotEmpty) {
        // Invalidate probes started on the previous Wi-Fi before refreshing.
        _heartbeatGeneration++;
        _checkingHeartbeat = false;
        unawaited(_refreshHeartbeats());
      }
    }
  }

  /// Fetch the version on a TLS-pinned, authenticated saved address.
  /// Never use subnet discovery to decide update badge visibility.
  Future<({bool online, String? version})> _probeSavedDevice(
      SavedComputer device, PhoneIdentity? phone, {String? atHost}) async {
    final connection = LocalAgent();
    try {
      connection.configure(atHost ?? device.host, device.token, device.fingerprint,
          identity: device.deviceId.isNotEmpty ? phone : null,
          deviceId: device.deviceId.isNotEmpty ? device.deviceId : null);
      final version = await connection.agentVersion()
          .timeout(const Duration(seconds: 3));
      if (version != null) return (online: true, version: version);
      await connection.send('ping').timeout(const Duration(seconds: 3));
      return (online: true, version: null);
    } catch (_) {
      return (online: false, version: null);
    } finally {
      connection.disconnect();
    }
  }

  Future<bool> _pingSavedDevice(
      SavedComputer device, PhoneIdentity? phone, {String? atHost}) async =>
      (await _probeSavedDevice(device, phone, atHost: atHost)).online;

  /// Display saved pairings first; heartbeat checks their existing IPs.
  /// Only a zero-online result triggers quiet UDP discovery.
  Future<void> _refreshHeartbeats() async {
    if (_checkingHeartbeat || _scanningToReconcile ||
        savedComputers.isEmpty) {
      return;
    }
    _checkingHeartbeat = true;
    final generation = ++_heartbeatGeneration;
    if (mounted) setState(() => _dashboardNotice = null);
    try {
      PhoneIdentity? phone;
      try {
        if (savedComputers.any((device) => device.deviceId.isNotEmpty)) {
          phone = await _phoneIdentity();
        }
      } catch (_) {}
      final savedSnapshot = savedComputers.toList();
      // Start every saved host immediately instead of waiting for discovery
      // broadcasts, subnet probes, or a preceding batch to time out.
      await Future.wait(savedSnapshot.map((device) async {
        final probe = await _probeSavedDevice(device, phone);
        if (!mounted || generation != _heartbeatGeneration) return;
        // Device may have been renamed/repaired while this ping was in flight.
        final stillSaved = savedComputers.any(
          (current) => current.id == device.id &&
              current.host == device.host &&
              current.fingerprint == device.fingerprint);
        if (!stillSaved) return;
        // A concurrent background heartbeat must not change an actively
        // connecting device to OFFLINE while its foreground login completes.
        if (_connectingDeviceId == device.id) return;
        setState(() {
          _online[device.id] = probe.online;
          if (probe.online && probe.version != null) {
            _savedAgentVersions[device.id] = probe.version!;
          } else {
            _savedAgentVersions.remove(device.id);
          }
        });
      }));
    } finally {
      if (generation == _heartbeatGeneration) {
        _checkingHeartbeat = false;
        if (mounted) setState(() {});
        if (mounted && savedComputers.isNotEmpty &&
            !_online.values.any((online) => online)) {
          unawaited(_recoverSavedDevices());
        }
      }
    }
  }

  // Recover saved pairings quietly when ALL saved hosts fail authenticated
  // heartbeats. UDP first, then a throttled, bounded TCP agent-port probe
  // when broadcast discovery is blocked by iOS or the Wi-Fi router.
  // Raw TCP acceptance is NEVER evidence of identity or an online device.
  Future<void> _recoverSavedDevices({bool force = false}) async {
    if (!mounted || !_appForeground || savedComputers.isEmpty ||
        _recoveringDiscovery || _scanningToReconcile) {
      return;
    }
    final now = DateTime.now();
    if (!force && _lastPassiveDiscovery != null &&
        now.difference(_lastPassiveDiscovery!) <
            const Duration(minutes: 10)) {
      return;
    }
    _lastPassiveDiscovery = now;
    _recoveringDiscovery = true;
    if (mounted) setState(() {});
    try {
      // Do not scan a stale cached CIDR if the user switched Wi-Fi.
      final network = await detectLanRange() ?? _wifiRange;
      if (network == null || !mounted) {
        return;
      }
      final candidates = await findNearbyDevices(
        duration: const Duration(seconds: 2),
        scanPrefixes: [network.activePrefix],
        broadcastOnly: true,
        broadcastAddress: lanBroadcastAddress(network),
      );
      for (final candidate in candidates.take(8)) {
        if (!mounted || !_appForeground) {
          return;
        }
        if (lanRangeContains(network, candidate.host)) {
          await _reconcileScannedAgent(candidate.host, passive: true);
        }
      }
      if (!mounted || !_appForeground ||
          _online.values.any((online) => online)) {
        return;
      }
      // A zero-online Wi-Fi is the only automatic TCP scan trigger.
      // At most 24 concurrent, 300ms per host and once every ten minutes.
      // Unlike manual discovery this scans ONLY the TapTether agent port.
      setState(() => _probingOfflineAgents = true);
      final responders = await probeAgentControlPorts(
        network,
        parallelism: 24,
        maxHits: 16,
        timeout: const Duration(milliseconds: 300),
      );
      var authenticated = 0;
      var unverifiedSavedAddress = false;
      final savedIps = savedComputers.map((device) => device.host).toSet();
      for (final address in responders) {
        if (!mounted || !_appForeground ||
            _online.values.any((online) => online)) {
          break;
        }
        if (_wifiRange != null &&
            !lanRangeContains(_wifiRange!, address)) {
          break;
        }
        final name = await _reconcileScannedAgent(address, passive: true);
        if (name != null) {
          authenticated++;
        } else if (savedIps.contains(address)) {
          unverifiedSavedAddress = true;
        }
      }
      if (mounted && authenticated == 0 &&
          !_online.values.any((online) => online) &&
          unverifiedSavedAddress) {
        setState(() {
          _dashboardNotice = 'An agent port responded at a saved address, '
              'but pairing authentication failed. Check or re-pair that '
              'computer from Manage.';
        });
      }
    } catch (_) {
      // No prompts, credential disclosure, or fatal errors during recovery.
    } finally {
      _recoveringDiscovery = false;
      _probingOfflineAgents = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _refreshDevicesManually() async {
    if (_checkingHeartbeat || _recoveringDiscovery ||
        _recoveringTvAddresses || _checkingTvStatus) return;
    await Future.wait([
      _refreshHeartbeats(),
      _refreshTvStatuses(),
    ]);
    await _recoverSavedDevices(force: true);
    await _recoverTvAddresses(force: true);
  }

  // Listen only in the foreground; iOS can suspend background sockets.
  // Unsolicited agent announcements are *hints*, never trusted pairings.
  Future<void> _listenForAgentAnnouncements() async {
    try {
      final socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, 48322);
      if (!mounted) { socket.close(); return; }
      _announcementSocket = socket;
      _announcementSubscription = socket.listen((event) {
        if (event != RawSocketEvent.read || !_appForeground) {
          return;
        }
        Datagram? packet;
        while ((packet = socket.receive()) != null) {
          final candidate = DiscoveredDevice.parse(packet!);
          final network = _wifiRange;
          if (candidate == null || network == null ||
              !lanRangeContains(network, candidate.host) ||
              savedComputers.isEmpty || _scanningToReconcile ||
              _recoveringDiscovery) {
            continue;
          }
          final now = DateTime.now();
          final last = _recentAnnouncements[candidate.host];
          if (last != null &&
              now.difference(last) < const Duration(minutes: 10)) {
            continue;
          }
          _recentAnnouncements[candidate.host] = now;
          if (_recentAnnouncements.length > 24) _recentAnnouncements.clear();
          unawaited(_reconcileScannedAgent(candidate.host,
              passive: true).then((_) {}));
        }
      });
    } catch (_) {
      // No permission or availability: foreground discovery is fallback.
    }
  }

  Future<void> _labelCurrentNetwork() async {
    final network = _wifiRange;
    if (network == null) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('This Wi-Fi network belongs to'),
        children: [
          for (final item in deviceLocations.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, item.key),
              child: Text(item.value),
            ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    await networkLocationStore.assign(network, choice);
    // Assign existing uncategorized devices inside this subnet to the
    // chosen location. Never override an explicitly selected category.
    for (final device in savedComputers.toList()) {
      if (device.location == 'other' &&
          lanRangeContains(network, device.host)) {
        await deviceStore.upsert(SavedComputer(
          id: device.id, name: device.name, host: device.host,
          token: device.token, fingerprint: device.fingerprint,
          platform: device.platform, deviceId: device.deviceId,
          customName: device.customName, location: choice,
          macAddress: device.macAddress,
        ));
      }
    }
    await loadComputers();
    await _refreshNetworkLocation();
  }

  Future<void> scanQrPairing() async {
    final scanned = await Navigator.of(context).push<PairingQR>(
      MaterialPageRoute(builder: (_) => const PairingScanner()),
    );
    if (scanned == null || !mounted) return;
    host.text = scanned.host;
    token.text = scanned.token;
    pin.text = scanned.fingerprint;
    discoveredName = scanned.host;
    await connect();
  }

  Future<void> openAgentInstaller() => _launchAgentInstaller();

  Future<void> _launchAgentInstaller({
    SavedComputer? device,
    bool updateOnly = false,
  }) async {
    if (installingAgent) return;
    setState(() => installingAgent = true);
    try {
      final address = device?.host ?? host.text.trim();
      final known = savedComputers.where((d) => d.host == address);
      final platform = device?.platform ?? agent.reportedPlatform ??
          (known.isNotEmpty ? known.first.platform : _connectedPlatform);
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => InstallAgentScreen(
          initialHost: address,
          knownPlatform: platform,
          updateOnly: updateOnly,
          onInstalled: (installed, installedPlatform) async {
            host.text = installed.host;
            token.text = installed.token;
            pin.text = installed.fingerprint;
            discoveredName = device?.name ?? installed.host;
            _connectedPlatform = installedPlatform;
            return connect();
          },
        ),
      ));
    } finally {
      if (mounted) setState(() => installingAgent = false);
    }
  }

  Future<void> loadComputers() async {
    try {
      final devices = await deviceStore.read();
      if (mounted) {
        setState(() {
          savedComputers = devices;
          final savedIds = devices.map((device) => device.id).toSet();
          _savedAgentVersions.removeWhere((id, _) => !savedIds.contains(id));
          _online.removeWhere((id, _) => !savedIds.contains(id));
        });
      }
      unawaited(_refreshHeartbeats());
      // Published metadata is fetched once per saved platform (only GitHub
      // release metadata, never a LAN discovery or computer-wide scan).
      for (final platform in devices.map((device) => device.platform).toSet()) {
        if (platform == 'linux' || platform == 'darwin' ||
            platform == 'windows') {
          unawaited(checkForUpdates(agentPlatform: platform));
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
            status = 'Saved devices could not be loaded. Check secure storage permissions.');
      }
    }
  }

  Future<Map<String, String>> _trustedMacDiscovery() async {
    final current = _wifiRange;
    if (current == null) return {};
    final candidates = savedComputers.where((device) =>
        lanRangeContains(current, device.host)).take(3);
    PhoneIdentity? phone;
    try {
      if (candidates.any((device) => device.deviceId.isNotEmpty)) {
        phone = await PhoneIdentity.loadOrCreate();
      }
    } catch (_) {}
    final combined = <String, String>{};
    for (final device in candidates) {
      final connection = LocalAgent();
      try {
        connection.configure(device.host, device.token, device.fingerprint,
            identity: device.deviceId.isNotEmpty ? phone : null,
            deviceId: device.deviceId.isNotEmpty ? device.deviceId : null);
        combined.addAll(await connection.trustedLanNeighbors());
      } catch (_) {
        // Offline or older agents cannot provide neighbor information.
      } finally {
        connection.disconnect();
      }
    }
    return combined;
  }

  /// A scan discovers IP addresses, never trusted identities. This verifies
  /// each candidate against the original saved certificate and authenticated
  /// pairing before immediately replacing an outdated DHCP address.
  Future<String?> _reconcileScannedAgent(String ip,
      {bool passive = false}) async {
    if (!mounted || !isPrivateIPv4(ip) || savedComputers.isEmpty) {
      return null;
    }
    PhoneIdentity? phone;
    try {
      if (savedComputers.any((d) => d.deviceId.isNotEmpty)) {
        phone = await PhoneIdentity.loadOrCreate();
      }
    } catch (_) {}
    final snapshots = savedComputers.toList()..sort((a, b) =>
        (a.host == ip ? 0 : 1).compareTo(b.host == ip ? 0 : 1));
    for (final saved in snapshots) {
      if (!mounted || !(await _pingSavedDevice(saved, phone, atHost: ip))) {
        continue;
      }
      if (!passive && _scanVerifiedDeviceIds.contains(saved.id)) {
        return saved.name;
      }
      if (!passive) _scanVerifiedDeviceIds.add(saved.id);
      if (saved.host == ip) {
        if (mounted) setState(() => _online[saved.id] = true);
        return saved.name;
      }
      try {
        final verified = movedDevice(saved, ip,
            currentLocation: _detectedLocation);
        final refreshed = await deviceStore.upsert(verified);
        if (!mounted) return null;
        setState(() {
          savedComputers = refreshed;
          _online[saved.id] = true;
        });
        // Leave the user in the scan screen; the matching My Devices entry
        // is already updated and will open the correct IP when selected.
        return verified.name;
      } catch (_) {
        _scanVerifiedDeviceIds.remove(saved.id);
        return null;
      }
    }
    return null;
  }

  Future<Map<String, String>> _reconcileDiscoveredAgents(
      List<DiscoveredDevice> results) async {
    final recognized = <String, String>{};
    for (final result in results) {
      final name = await _reconcileScannedAgent(result.host);
      if (name != null) recognized[result.host] = name;
    }
    return recognized;
  }

  Future<void> scanNetwork() async {
    if (_scanningToReconcile) return;
    _scanningToReconcile = true;
    _scanVerifiedDeviceIds.clear();
    String? selected;
    try {
      selected = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) =>
            LanScanScreen(initialIp: host.text.trim(),
                knownComputers: savedComputers,
                macResolver: _trustedMacDiscovery,
                verifyPairedAgent: _reconcileScannedAgent)),
      );
    } finally {
      _scanningToReconcile = false;
      _scanVerifiedDeviceIds.clear();
    }
    if (selected == null || !mounted) return;
    PhoneIdentity? phone;
    try {
      if (savedComputers.any((d) => d.deviceId.isNotEmpty)) {
        phone = await PhoneIdentity.loadOrCreate();
      }
    } catch (_) {}
    for (final device in savedComputers.toList()) {
      if (await _pingSavedDevice(device, phone, atHost: selected)) {
        final moved = movedDevice(device, selected,
            currentLocation: _detectedLocation);
        try { await deviceStore.upsert(moved); } catch (_) {}
        if (mounted) await connectSaved(moved);
        return;
      }
    }
    if (!mounted) return;
    agent.disconnect();
    setState(() {
      host.text = selected!;
      discoveredName = selected;
      _showPairForm = true;
      status = 'Selected $selected from LAN scan. Pairing credentials are still required.';
    });
  }

  Future<void> searchNearby() async {
    if (searching || _scanningToReconcile) return;
    _scanningToReconcile = true;
    _scanVerifiedDeviceIds.clear();
    _discoveryReport.clear();
    _discoveryReport.add('Discover initiated by phone (no background scan)');
    setState(() {
      searching = true;
      nearbyComputers = [];
      status = 'Looking for TapTether agents on the local network…';
    });
    try {
      // Read the Wi-Fi again so a recent SSID switch does not reuse a
      // stale subnet from the preceding heartbeat refresh.
      final wifi = await detectLanRange() ?? _wifiRange;
      _discoveryReport.add('Wi-Fi: ${wifi?.ip ?? "unknown"} · '
          'CIDR: ${wifi?.cidr ?? "unknown"}');
      final prefixes = wifi?.scanPrefixes.take(8).toList();
      _discoveryReport.add('UDP discovery: broadcast + unicast on port 48322 · '
          'ranges ${prefixes?.map((p) => "$p.0/24").join(", ") ?? "system detected"}');
      final result = await findNearbyDevices(scanPrefixes: prefixes);
      if (!mounted) return;
      _discoveryReport.add('UDP responses: ${result.length}');
      for (final found in result) {
        _discoveryReport.add('${found.host}: UDP announcement '
            '(unverified, platform ${found.platform})');
      }
      final verified = await _reconcileDiscoveredAgents(result);
      if (!mounted) return;
      final allCandidates = <String, DiscoveredDevice>{
        for (final found in result) found.host: found,
      };
      // A user-requested Discover also probes the agent TCP port on all
      // on-link /24 slices of up to a /22, even with no saved pairing.
      // This gives unpaired agents a chance to appear when UDP is blocked.
      // Open ports remain UNTRUSTED until pairing/TLS authentication.
      if (verified.isEmpty && wifi != null) {
        _discoveryReport.add('TCP fallback: probe port 48321 on Wi-Fi CIDR '
            '(320ms per host, up to 1024 addresses; max 24 results)');
        var attempted = 0;
        final ips = await probeAgentControlPorts(wifi,
          onProbe: (ip, accepts) {
            attempted++;
            _discoveryReport.add('$ip: TCP 48321 '
                '${accepts ? "accepted (unverified)" : "no connection"}');
          },
        );
        _discoveryReport.add('TCP fallback complete: $attempted addresses '
            'checked; ${ips.length} TCP responder(s)');
        for (final ip in ips) {
          if (!mounted) break;
          final name = await _reconcileScannedAgent(ip);
          if (name != null) {
            verified[ip] = name;
            _discoveryReport.add('$ip: saved pairing authenticated');
          } else {
            _discoveryReport.add('$ip: not authenticated as saved pairing');
            allCandidates.putIfAbsent(ip, () => DiscoveredDevice(
              name: 'Possible TapTether agent (unverified)',
              host: ip,
              platform: 'TCP 48321',
              version: 'unknown',
            ));
          }
        }
      } else if (verified.isNotEmpty) {
        _discoveryReport.add('TCP fallback skipped: paired computer found '
            'through UDP and authenticated');
      } else {
        _discoveryReport.add('TCP fallback unavailable: no Wi-Fi CIDR');
      }
      if (!mounted) return;
      _discoveryReport.add('Discover finished: '
          '${verified.length} existing paired computer(s) verified; '
          '${allCandidates.values.where((candidate) => !verified.containsKey(candidate.host)).length} unverified candidate(s)');
      setState(() {
        nearbyComputers = allCandidates.values.where((candidate) =>
            !verified.containsKey(candidate.host)).toList();
        status = verified.isNotEmpty
            ? 'Recognized ${verified.length} paired computer(s). My Devices is updated.'
            : nearbyComputers.isEmpty
                ? 'No agents found. See Full Discover Output below.'
                : 'Found ${nearbyComputers.length} unverified candidate(s). Pair to confirm.';
      });
    } catch (_) {
      _discoveryReport.add('Discover failed: network scan could not finish');
      if (mounted) {
        setState(() =>
            status = 'Discovery unavailable. See Full Discover Output.');
      }
    } finally {
      _scanningToReconcile = false;
      _scanVerifiedDeviceIds.clear();
      if (mounted) setState(() => searching = false);
    }
  }

  Future<void> selectDiscovered(DiscoveredDevice device) async {
    PhoneIdentity? phone;
    try {
      if (savedComputers.any((d) => d.deviceId.isNotEmpty)) {
        phone = await PhoneIdentity.loadOrCreate();
      }
    } catch (_) {}
    for (final saved in savedComputers.toList()) {
      if (await _pingSavedDevice(saved, phone, atHost: device.host)) {
        final moved = movedDevice(saved, device.host,
            currentLocation: _detectedLocation);
        try { await deviceStore.upsert(moved); } catch (_) {}
        if (mounted) await connectSaved(moved);
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      discoveredName = device.name;
      _connectedPlatform = device.platform;
      _macShortcuts = device.platform == 'darwin';
      _showPairForm = true;
      host.text = device.host;
      token.clear();
      pin.clear();
      status = 'Discovered ${device.name}. Enter its token and certificate fingerprint to verify ownership.';
    });
  }

  Future<void> connectSaved(SavedComputer device) async {
    // Dashboard taps never initiate a network request to a known-offline
    // machine. Refresh conducts a bounded, authenticated reachability test;
    // an online result is required before opening the remote.
    if (!canConnectSavedDevice(_online[device.id],
        connecting: _connectingDeviceId != null)) {
      return;
    }
    setState(() {
      _connectingDeviceId = device.id;
      _dashboardNotice = null;
    });
    var succeeded = false;
    try {
      host.text = device.host;
      token.text = device.token;
      pin.text = device.fingerprint;
      discoveredName = device.name;
      _connectedPlatform = device.platform;
      _macShortcuts = device.platform == 'darwin';
      succeeded = await connect(existingId: device.id, deviceId: device.deviceId);
    } catch (_) {
      // Saved device connection failures should not dump exception strings
      // containing LAN address/port onto the main dashboard.
      agent.disconnect();
    } finally {
      if (mounted) {
        setState(() {
          _connectingDeviceId = null;
          if (!succeeded) {
            agent.disconnect();
            _online[device.id] = false;
            _savedAgentVersions.remove(device.id);
            _dashboardNotice = '${device.name} did not respond. '
                'Check TapTether Agent on that computer and tap Refresh.';
          }
        });
      }
    }
  }

  Future<void> updateSavedAgent(SavedComputer device) async {
    if (device.platform != 'linux' && device.platform != 'darwin' &&
        device.platform != 'windows') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('This operating system has no supported updater.'),
      ));
      return;
    }
    // A saved device may be online yet run a different agent build from
    // the iPhone app. Read its actual version over the authenticated,
    // TLS-pinned channel and refresh the published release metadata before
    // showing an actionable update confirmation.
    String? installedAgentVersion;
    final inspector = LocalAgent();
    try {
      final phone = device.deviceId.isEmpty
          ? null : await PhoneIdentity.loadOrCreate();
      inspector.configure(device.host, device.token, device.fingerprint,
          identity: phone,
          deviceId: device.deviceId.isEmpty ? null : device.deviceId);
      installedAgentVersion = await inspector.agentVersion();
      if (mounted && installedAgentVersion != null) {
        setState(() => _savedAgentVersions[device.id] = installedAgentVersion!);
      }
    } catch (_) {
      // An unreachable or legacy agent has an unknown version.
    } finally {
      inspector.disconnect();
    }
    await checkForUpdates(agentPlatform: device.platform);
    if (!mounted) return;
    final check = AgentUpdateCheck(
      installed: installedAgentVersion,
      published: _latestAgentByPlatform[device.platform] ?? _latestReleaseVersion,
    );
    final approved = await showDialog<bool>(
      context: context,
      builder: (_) => AgentUpdateDialog(
        computerName: device.name,
        check: check,
      ),
    );
    if (approved != true || !mounted || !check.canUpdate) return;
    // Existing installed agents own the update action and verify the release.
    // Ubuntu requires the user to have separately enabled noninteractive sudo.
    // Older agents or machines without it retain the SSH GUI fallback.
    if (device.platform == 'darwin' ||
        device.platform == 'linux' || device.platform == 'windows') {
      final client = LocalAgent();
      try {
        final phone = device.deviceId.isEmpty
            ? null : await PhoneIdentity.loadOrCreate();
        client.configure(device.host, device.token, device.fingerprint,
            identity: phone,
            deviceId: device.deviceId.isEmpty ? null : device.deviceId);
        if (await client.requestUpdate()) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Update started on ${device.name}.'),
            ));
          }
          return;
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(
              'Direct update unavailable. Opening SSH update instead.')),
          );
        }
      } finally {
        client.disconnect();
      }
    }
    // SSH fallback uses only the package already bundled with this app.
    // Never replace a newer installed agent with an older bundled installer
    // just because an independent platform-only release is available.
    // The app can lag behind newer full releases too. Compare the computer
    // against THIS INSTALLED APP's embedded agent version, not the latest
    // version advertised on the internet.
    String? bundledAgentVersion;
    try {
      final appInfo = await PackageInfo.fromPlatform();
      bundledAgentVersion = '${appInfo.version}+${appInfo.buildNumber}';
    } catch (_) {}
    if (installedAgentVersion == null || bundledAgentVersion == null ||
        !newerThan(bundledAgentVersion, installedAgentVersion)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The bundled SSH installer cannot be verified as '
              'newer. Use the computer tray instead for its verified '
              'platform-only update, or install a newer phone app.'),
        ));
      }
      return;
    }
    if (mounted) {
      await _launchAgentInstaller(device: device, updateOnly: true);
    }
  }

  Future<void> forgetComputer(SavedComputer device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Forget ${device.name}?'),
        content: const Text('Its saved token and certificate fingerprint will be erased from this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Forget')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = await deviceStore.remove(device.id);
      if (mounted) setState(() => savedComputers = updated);
    } catch (_) {
      if (mounted) setState(() => status = 'Cannot erase saved pairing from secure storage.');
    }
  }

  Future<void> loadLgTvs() async {
    try {
      final tvs = await LgTvStore().read();
      if (mounted) {
        setState(() => savedLgTvs = tvs);
        unawaited(_refreshTvStatuses());
      }
    } catch (_) {
      // TV remote storage may be unavailable until iOS Keychain unlocks.
    }
  }

  Future<void> loadSamsungTvs() async {
    try {
      final tvs = await SamsungTvStore().read();
      if (mounted) {
        setState(() => savedSamsungTvs = tvs);
        unawaited(_refreshTvStatuses());
      }
    } catch (_) {
      // Samsung pairing tokens stay in the device secure store.
    }
  }

  Future<void> _refreshTvStatuses() async {
    if (!mounted || !_appForeground || _checkingTvStatus) return;
    _checkingTvStatus = true;
    if (mounted) setState(() {});
    try {
      final lan = await detectLanRange() ?? _wifiRange;
      final lg = savedLgTvs.toList();
      final samsung = savedSamsungTvs.toList();
      await Future.wait(<Future<void>>[
        for (final tv in lg) () async {
          final key = 'lg:${tv.host}';
          final reachable = lan != null &&
              lanRangeContains(lan, tv.host) && await lgTvResponds(tv);
          if (!mounted) return;
          setState(() {
            _tvOnline[key] = reachable;
            if (reachable) _tvLastSeen[key] = DateTime.now();
          });
        }(),
        for (final tv in samsung) () async {
          final key = 'samsung:${tv.host}';
          final reachable = lan != null &&
              lanRangeContains(lan, tv.host) &&
              await samsungTvResponds(tv);
          if (!mounted) return;
          setState(() {
            _tvOnline[key] = reachable;
            if (reachable) _tvLastSeen[key] = DateTime.now();
          });
        }(),
      ]);
    } catch (_) {
      // No speculative online status after probe failures.
    } finally {
      _checkingTvStatus = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _recoverTvAddresses({bool force = false}) async {
    if (!mounted || !_appForeground || _recoveringTvAddresses) return;
    final now = DateTime.now();
    if (!force && _lastTvRecovery != null &&
        now.difference(_lastTvRecovery!) < const Duration(minutes: 10)) {
      return;
    }
    final network = await detectLanRange() ?? _wifiRange;
    if (network == null || !mounted) return;
    // No broad scan while devices are reachable, or without a stable ID.
    final missingLg = savedLgTvs.where((tv) =>
        _tvOnline['lg:${tv.host}'] != true &&
        tv.deviceUuid.isNotEmpty && tv.tlsPin.isNotEmpty &&
        (!lanRangeContains(network, tv.host) ||
            _tvOnline['lg:${tv.host}'] == false)).take(4).toList();
    final missingSamsung = savedSamsungTvs.where((tv) =>
        _tvOnline['samsung:${tv.host}'] != true &&
        (tv.deviceId.isNotEmpty || tv.macAddress.isNotEmpty) &&
        (!lanRangeContains(network, tv.host) ||
            _tvOnline['samsung:${tv.host}'] == false)).take(4).toList();
    if (missingLg.isEmpty && missingSamsung.isEmpty) return;
    _lastTvRecovery = now;
    _recoveringTvAddresses = true;
    setState(() {});
    try {
      // Scan only on the active LAN, with bounded concurrency. Match UUID/MAC
      // first, then require existing TLS-pinned credentials before updating IP.
      for (final tv in missingLg) {
        if (!mounted || !_appForeground) break;
        final recovered = await relocateLgTv(tv);
        if (recovered != null) await loadLgTvs();
      }
      for (final tv in missingSamsung) {
        if (!mounted || !_appForeground) break;
        final recovered = await relocateSamsungTv(tv);
        if (recovered != null) await loadSamsungTvs();
      }
    } finally {
      _recoveringTvAddresses = false;
      if (mounted) {
        setState(() {});
        unawaited(_refreshTvStatuses());
      }
    }
  }

  Future<void> openSamsungTv({String? host}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SamsungTvScreen(
        initialHost: host,
        initialLocation: _detectedLocation ?? 'other',
        onSaved: loadSamsungTvs,
      ),
    ));
    if (mounted) {
      await loadSamsungTvs();
      unawaited(_refreshTvStatuses());
    }
  }

  Future<void> openLgWebOs({String? host}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LgWebOsScreen(
        initialHost: host,
        initialLocation: _detectedLocation ?? 'other',
        onSaved: loadLgTvs,
      ),
    ));
    if (mounted) await loadLgTvs();
  }

  Future<void> openDeviceManager() async {
    final addNew = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DeviceManagerScreen(
        store: deviceStore,
        online: Map<String, bool>.of(_online),
        onConnect: connectSaved,
        onUpdate: updateSavedAgent,
      ),
    ));
    if (!mounted) return;
    await loadComputers();
    if (addNew == true && mounted) setState(() => _showPairForm = true);
  }

  Future<void> openSshKeys() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const SshKeyScreen(),
    ));
  }

  Future<void> openSecuritySettings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const SecuritySettingsScreen(),
    ));
  }

  void showPairForm() {
    _stopScreen();
    if (agent.configured) agent.disconnect();
    setState(() {
      _showPairForm = true;
      status = 'Enter verified computer pairing details.';
    });
  }

  Widget appDrawer() => Drawer(
    child: SafeArea(child: ListView(
      padding: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset('assets/branding/taptether.png',
                  width: 54, height: 54),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TapTether',
                    style: Theme.of(context).textTheme.titleLarge),
                const Text('Your network. Your control.'),
              ],
            )),
          ]),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.devices_outlined),
          title: const Text('My Devices'),
          onTap: () {
            Navigator.pop(context);
            if (agent.configured) {
              agent.disconnect();
              setState(() => status = 'Select a device to connect.');
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.tv_outlined),
          title: const Text('LG webOS TV'),
          onTap: () {
            Navigator.pop(context);
            openLgWebOs();
          },
        ),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('SSH Keys'),
          onTap: () {
            Navigator.pop(context);
            openSshKeys();
          },
        ),
        ExpansionTile(
          leading: const Icon(Icons.add_circle_outline),
          title: const Text('Add & Discover'),
          childrenPadding: const EdgeInsets.only(left: 16),
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Pair computer'),
              onTap: () {
                Navigator.pop(context);
                showPairForm();
              },
            ),
            ListTile(
              leading: const Icon(Icons.tv_outlined),
              title: const Text('Add LG webOS TV'),
              onTap: () {
                Navigator.pop(context);
                openLgWebOs();
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Scan QR'),
              onTap: () {
                Navigator.pop(context);
                scanQrPairing();
              },
            ),
            ListTile(
              leading: const Icon(Icons.radar),
              title: const Text('Discover computers'),
              onTap: () {
                Navigator.pop(context);
                if (agent.configured) agent.disconnect();
                searchNearby();
              },
            ),
            ListTile(
              leading: const Icon(Icons.network_check),
              title: const Text('Scan local IP network'),
              onTap: () {
                Navigator.pop(context);
                scanNetwork();
              },
            ),
            ListTile(
              leading: const Icon(Icons.install_desktop),
              title: const Text('Install Agent'),
              onTap: installingAgent ? null : () {
                Navigator.pop(context);
                openAgentInstaller();
              },
            ),
          ],
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Security & Appearance'),
          onTap: () {
            Navigator.pop(context);
            openSecuritySettings();
          },
        ),
        AboutListTile(
          icon: const Icon(Icons.info_outline),
          applicationName: 'TapTether',
          applicationVersion: installedVersion,
          child: const Text('About'),
        ),
      ],
    )),
  );

  Widget _deviceStatus(String id) {
    final state = _online[id];
    final busy = _connectingDeviceId == id && state == true;
    final checking = state != true &&
        (_checkingHeartbeat || _recoveringDiscovery);
    final color = state == true
        ? Colors.green.shade700
        : state == false
            ? Theme.of(context).colorScheme.outline
            : Theme.of(context).colorScheme.secondary;
    final label = busy
        ? 'CONNECTING' : state == true
            ? 'ONLINE' : checking
                ? (_probingOfflineAgents ? 'LOCATING' : 'CHECKING')
                : state == false ? 'OFFLINE' : 'CHECKING';
    return Semantics(
      label: 'Computer ${busy ? 'connecting' : label.toLowerCase()}',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy)
          SizedBox(width: 13, height: 13,
            child: CircularProgressIndicator(strokeWidth: 2, color: color))
        else
          Icon(state == true ? Icons.check_circle :
              state == false ? Icons.circle_outlined : Icons.circle,
              size: 15, color: color),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: color,
            fontSize: 11, fontWeight: FontWeight.w800,
            letterSpacing: 0.35)),
      ]),
    );
  }

  bool _tvVisible(String location, String key) {
    final selected = _locationFilter == 'automatic'
        ? _detectedLocation : _locationFilter;
    final matchingLocation = selected == 'all' ||
        (selected == null && _locationFilter == 'automatic') ||
        location == selected ||
        (location == 'other' && _tvOnline[key] == true &&
            _locationFilter == 'automatic');
    return matchingLocation && (_showOffline || _tvOnline[key] == true);
  }

  Widget _tvStatus(String vendor, String host) {
    final key = '$vendor:$host';
    final outside = _wifiRange != null &&
        !lanRangeContains(_wifiRange!, host);
    final online = _tvOnline[key] == true;
    final checking = _checkingTvStatus || _recoveringTvAddresses;
    final label = online ? 'ONLINE'
        : outside ? 'OTHER NETWORK'
        : checking ? 'CHECKING' : 'OFFLINE';
    final color = online ? Colors.green.shade700 :
        Theme.of(context).colorScheme.outline;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(online ? Icons.check_circle : Icons.circle_outlined,
          size: 15, color: color),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(
          fontSize: 10, color: color, fontWeight: FontWeight.w700)),
    ]);
  }

  Future<void> _chooseTvType() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.tv_outlined),
            title: const Text('LG webOS TV'),
            subtitle: const Text('Agent-free, local TV pairing'),
            onTap: () {
              Navigator.pop(sheet);
              unawaited(openLgWebOs());
            },
          ),
          ListTile(
            leading: const Icon(Icons.tv),
            title: const Text('Samsung Smart TV'),
            subtitle: const Text('Tizen / Smart View local pairing'),
            onTap: () {
              Navigator.pop(sheet);
              unawaited(openSamsungTv());
            },
          ),
        ],
      )),
    );
  }

  Widget deviceDashboard() {
    final visibleDevices = visibleSavedDevices(
      savedComputers,
      online: _online,
      locationFilter: _locationFilter,
      currentLocation: _detectedLocation,
      currentNetwork: _wifiRange,
      showOffline: _showOffline,
    );
    final onlineComputerCount =
        savedComputers.where((tv) => _online[tv.id] == true).length;
    final onlineTvCount =
        savedLgTvs.where((tv) => _tvOnline['lg:${tv.host}'] == true).length +
        savedSamsungTvs.where((tv) =>
            _tvOnline['samsung:${tv.host}'] == true).length;
    final availabilityHint = savedDeviceAvailabilityHint(
      savedCount: savedComputers.length,
      onlineCount: savedComputers.where((d) => _online[d.id] == true).length,
      checking: _checkingHeartbeat || _recoveringDiscovery,
    );
    return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Expanded(child: Text('My Devices',
          style: Theme.of(context).textTheme.headlineSmall)),
        TextButton.icon(
          onPressed: openDeviceManager,
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Manage'),
        ),
      ]),
      const SizedBox(height: 8),
      if (savedComputers.isNotEmpty || savedLgTvs.isNotEmpty ||
          savedSamsungTvs.isNotEmpty) ...[
        Row(children: [
          Expanded(child: DropdownButtonFormField<String>(
            key: const ValueKey('device-location-filter'),
            initialValue: _locationFilter,
            decoration: const InputDecoration(
              isDense: true, labelText: 'Location'),
            items: [
              DropdownMenuItem(value: 'automatic',
                child: Text(_detectedLocation == null
                    ? 'Current network'
                     : 'Current · ${deviceLocations[_detectedLocation]!}')),
              const DropdownMenuItem(
                value: 'all', child: Text('All locations')),
              for (final category in deviceLocations.entries)
                DropdownMenuItem(value: category.key, child: Text(category.value)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _locationFilter = value);
            },
          )),
          IconButton(
            tooltip: 'Refresh computers and TVs',
            onPressed: (_checkingHeartbeat || _recoveringDiscovery ||
                _checkingTvStatus || _recoveringTvAddresses)
                 ? null : _refreshDevicesManually,
            icon: const Icon(Icons.refresh),
          ),
        ]),
        Row(children: [
          Checkbox(
            key: const ValueKey('show-offline-devices'),
            value: _showOffline,
            onChanged: (value) => setState(() => _showOffline = value ?? false),
          ),
          const Text('Show offline'),
          const Spacer(),
          Text(
            '$onlineComputerCount computer${onlineComputerCount == 1 ? '' : 's'}'
             ' · $onlineTvCount TV${onlineTvCount == 1 ? '' : 's'} online',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600),
          ),
        ]),
        if (_recoveringTvAddresses)
          Text('Locating saved TVs by verified identity…',
            style: Theme.of(context).textTheme.bodySmall),
        if (_checkingTvStatus && !_checkingHeartbeat)
          Text('Checking saved TVs…',
            style: Theme.of(context).textTheme.bodySmall),
        if (_recoveringDiscovery)
          Text(_probingOfflineAgents
              ? 'Checking TapTether agent addresses on this Wi-Fi…'
              : 'Finding paired computers on this Wi-Fi…',
            style: Theme.of(context).textTheme.bodySmall),
        if (_checkingHeartbeat)
          Text('Checking saved devices…',
            style: Theme.of(context).textTheme.bodySmall),
        if (_dashboardNotice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_dashboardNotice!,
              key: const ValueKey('device-connection-notice'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (availabilityHint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(availabilityHint,
              key: const ValueKey('devices-offline-hint'),
              style: Theme.of(context).textTheme.bodySmall),
          ),
        const SizedBox(height: 8),
        if (visibleDevices.isEmpty && savedComputers.isNotEmpty &&
            savedLgTvs.isEmpty && savedSamsungTvs.isEmpty)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(_checkingHeartbeat
                ? 'Checking saved devices…'
                : 'No saved devices match this filter. Change the location '
                  'or enable Show offline.'),
          ),
      ],
      if (savedComputers.isEmpty && savedLgTvs.isEmpty &&
          savedSamsungTvs.isEmpty)
        Card(child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.devices_other_outlined, size: 36),
              const SizedBox(height: 12),
              Text('No computers paired yet',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text('Pair a computer on your local network '
                  'to reconnect with a single tap.'),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: showPairForm,
                icon: const Icon(Icons.add),
                label: const Text('Pair computer'),
              ),
            ],
          ),
        ))
      else
        for (final device in visibleDevices)
          Card(
            key: ValueKey('saved-device-${device.id}'),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 5),
              leading: Icon(device.platform == 'darwin'
                  ? Icons.laptop_mac : Icons.computer,
                  size: 29),
              title: Text(device.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                savedComputers.where((other) =>
                    other.host == device.host && other.id != device.id)
                    .isNotEmpty && _online[device.id] != true
                    ? '${device.host} · Shared/stale IP · Verify identity'
                    : '${device.host} · ${deviceLocations[device.location] ?? 'Other'}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (_online[device.id] == true &&
                    (device.platform == 'linux' ||
                     device.platform == 'darwin' ||
                     device.platform == 'windows') &&
                    showSavedAgentUpdate(
                      online: _online[device.id],
                      installed: _savedAgentVersions[device.id],
                      published: _latestAgentByPlatform[device.platform] ??
                          _latestReleaseVersion,
                    ))
                  IconButton(
                    tooltip: 'Check agent update',
                    onPressed: () => updateSavedAgent(device),
                    icon: const Icon(Icons.system_update_alt),
                    visualDensity: VisualDensity.compact,
                  ),
                const SizedBox(width: 4),
                _deviceStatus(device.id),
              ]),
              onTap: canConnectSavedDevice(_online[device.id],
                      connecting: _connectingDeviceId != null)
                  ? () => connectSaved(device) : null,
            ),
          ),

      // TVs share the same device-card surface; their authenticated pairing
      // is preserved independently of desktop agent credentials.
      for (final tv in savedLgTvs)
        Card(
          key: ValueKey('lg-tv-${tv.deviceUuid.isNotEmpty
              ? tv.deviceUuid : tv.host}'),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 5),
            leading: const Icon(Icons.tv_outlined, size: 29),
            title: Text(tv.name,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('${tv.host} · LG webOS',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.link, size: 14),
              SizedBox(width: 4),
              Text('PAIRED', style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700)),
              Icon(Icons.chevron_right),
            ]),
            onTap: () => openLgWebOs(host: tv.host),
          ),
        ),
      if (savedLgTvs.isEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => openLgWebOs(),
            icon: const Icon(Icons.tv_outlined),
            label: const Text('Add LG webOS TV'),
          ),
        ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('quick-actions-toggle'),
          onPressed: () => setState(
              () => _showQuickActions = !_showQuickActions),
          icon: Icon(_showQuickActions
              ? Icons.expand_less : Icons.add_circle_outline),
          label: Text(_showQuickActions
              ? 'Hide add & discovery tools' : 'Add / Discover'),
        ),
      ),
      if (_showQuickActions) ...[
        const SizedBox(height: 4),
        if (_wifiRange != null)
          Row(children: [
            Expanded(child: Text('Wi-Fi: ${_wifiRange!.cidr}',
              style: Theme.of(context).textTheme.bodySmall)),
            TextButton.icon(
              onPressed: _labelCurrentNetwork,
              icon: const Icon(Icons.location_on_outlined, size: 16),
              label: const Text('Label network'),
            ),
          ]),
        for (final nearby in nearbyComputers)
          Card(child: ListTile(
            leading: const Icon(Icons.radar),
            title: Text(nearby.name),
            subtitle: Text('${nearby.host} · ${nearby.platform}'),
            trailing: const Icon(Icons.add_link),
            onTap: () => selectDiscovered(nearby),
          )),
        Wrap(spacing: 8, runSpacing: 4, children: [
          ActionChip(
            avatar: const Icon(Icons.add, size: 18),
            label: const Text('Pair'),
            onPressed: showPairForm,
          ),
          ActionChip(
            avatar: const Icon(Icons.qr_code_scanner, size: 18),
            label: const Text('Scan QR'),
            onPressed: scanQrPairing,
          ),
          ActionChip(
            avatar: const Icon(Icons.radar, size: 18),
            label: Text(searching ? 'Searching…' : 'Discover'),
            onPressed: searching ? null : searchNearby,
          ),
          ActionChip(
            avatar: const Icon(Icons.network_check, size: 18),
            label: const Text('Scan IPs'),
            onPressed: scanNetwork,
          ),
          ActionChip(
            avatar: const Icon(Icons.install_desktop, size: 18),
            label: const Text('Install agent'),
            onPressed: installingAgent ? null : openAgentInstaller,
          ),
        ]),
        if (searching || !_discoveryReport.isEmpty)
          ScanReportPanel(
            title: 'Discovery results',
            report: _discoveryReport,
          ),
      ],
    ],
   );
  }

  bool newerThan(String latest, String installed) {
    final pattern = RegExp(r'^([0-9]+)[.]([0-9]+)[.]([0-9]+)(?:[+]([0-9]+))?');
    final a = pattern.firstMatch(latest);
    final b = pattern.firstMatch(installed);
    if (a == null || b == null) return false;
    for (var i = 1; i <= 4; i++) {
      final left = int.parse(a.group(i) ?? '0');
      final right = int.parse(b.group(i) ?? '0');
      if (left != right) return left > right;
    }
    return false;
  }

  Future<void> loadInstalledVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() =>
          installedVersion = '${info.version}+${info.buildNumber}');
      }
    } catch (_) {
      if (mounted) {
        setState(() => installedVersion = 'unavailable');
      }
    }
  }

  // The iPhone/Android application stays on the full AltStore release.
  // Desktop agents may advance independently in their own GitHub feeds.
  Future<String> _latestPlatformAgentVersion(
      HttpClient client, String platform, String fullVersion) async {
    const platforms = {
      'linux': ('ubuntu-current', 'Ubuntu', 'Ubuntu'),
      'darwin': ('macos-current', 'macOS', 'macOS'),
      'windows': ('windows-current', 'Windows', 'Windows'),
    };
    final selected = platforms[platform];
    if (selected == null) return fullVersion;
    try {
      final req = await client.getUrl(Uri.parse(
        'https://api.github.com/repos/ssnanda/taptether.com/releases/tags/${selected.$1}'));
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      req.headers.set(HttpHeaders.userAgentHeader, 'TapTether-Mobile-Release-Check');
      final response = await req.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return fullVersion; // An absent optional platform feed is normal.
      }
      final data = jsonDecode(await utf8.decoder.bind(response).join());
      if (data is! Map || data['tag_name'] != selected.$1 ||
          data['name'] is! String || data['assets'] is! List) {
        return fullVersion;
      }
      final match = RegExp(
        r'^TapTether (Ubuntu|macOS|Windows) ([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)(?:\s|$)',
      ).firstMatch(data['name'] as String);
      if (match == null || match.group(1) != selected.$2) return fullVersion;
      final name = 'TapTetherAgent-${selected.$3}-'
          '${platform == 'windows' ? 'amd64.zip' : platform == 'darwin' ? 'amd64.tar.gz' : 'amd64.deb'}';
      final matching = (data['assets'] as List).whereType<Map>().where(
          (asset) => asset['name'] == name).toList();
      if (matching.length != 1) return fullVersion;
      final asset = matching.single;
      if (asset['digest'] is! String ||
          !RegExp(r'^sha256:[a-fA-F0-9]{64}$')
              .hasMatch(asset['digest'] as String) ||
          asset['browser_download_url'] !=
              'https://github.com/ssnanda/taptether.com/releases/download/${selected.$1}/$name') {
        return fullVersion;
      }
      final agentVersion = match.group(2)!;
      return newerThan(agentVersion, fullVersion)
          ? agentVersion : fullVersion;
    } catch (_) {
      // Network access is optional. LAN remote control remains fully local.
      return fullVersion;
    }
  }

  Future<void> checkForUpdates({String? agentPlatform}) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(Uri.parse(
        'https://raw.githubusercontent.com/ssnanda/taptether.com/main/altstore.json'));
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return;
      final data = jsonDecode(await utf8.decoder.bind(response).join());
      if (data is! Map || data['apps'] is! List) return;
      final apps = data['apps'] as List;
      if (apps.isEmpty || apps.first is! Map) return;
      final app = apps.first as Map;
      if (app['version'] is! String || app['buildVersion'] == null) return;
      final latest = "${app['version']}+${app['buildVersion']}";
      final platform = agentPlatform ?? _connectedPlatform;
      final latestAgent = platform == null ? latest :
          await _latestPlatformAgentVersion(client, platform, latest);
      final local = await PackageInfo.fromPlatform();
      final current = '${local.version}+${local.buildNumber}';
      if (!mounted) return;
      setState(() {
        _latestReleaseVersion = latest;
        if (platform != null) _latestAgentByPlatform[platform] = latestAgent;
        availableAppVersion = newerThan(latest, current) ? latest : null;
        final selected = _latestAgentByPlatform[_connectedPlatform] ?? latest;
        availableAgentVersion = connectedAgentVersion != null &&
                newerThan(selected, connectedAgentVersion!)
            ? selected : null;
      });
    } catch (_) {
      // LAN control remains usable without internet access.
    } finally {
      client.close(force: true);
    }
  }

  Widget updateNotices() => Column(children: [
    if (availableAppVersion != null) Card(child: ListTile(
      leading: const Icon(Icons.system_update),
      title: Text('TapTether ${availableAppVersion!} available'),
      subtitle: const Text('View the new IPA in AltStore / GitHub Releases.'),
      trailing: const Icon(Icons.open_in_new),
      onTap: () => launchUrl(
        Uri.parse('https://github.com/ssnanda/taptether.com/releases/tag/current'),
        mode: LaunchMode.externalApplication),
    )),
    if (availableAgentVersion != null) Card(child: ListTile(
      leading: const Icon(Icons.computer),
      title: Text('Computer agent update: ${availableAgentVersion!}'),
      subtitle: const Text('On the computer, run taptetherctl check-update and update.'),
    )),
  ]);

  Future<void> confirmShutdown() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Shut down this computer?'),
        content: const Text('Open applications will close and unsaved work may be lost.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Shut down')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await agent.send('shutdown');
      if (mounted) setState(() => status = 'Shutdown requested.');
    } catch (e) {
      _handleRemoteFailure(e);
    }
  }


  final Map<int, Offset> _touches = {};
  double? _pinchStart;
  bool _pinching = false;
  double _swipeX = 0;
  bool _swipeSent = false;
  bool _multiTouchGesture = false;
  final _trackpadScroll = SteppedScroll();
  int _pendingScroll = 0;
  Timer? _scrollTimer;
  bool _scrollInFlight = false;
  double mouseSensitivity = 3.8;

  void _touchDown(PointerDownEvent e) {
    if (_touches.isEmpty) _multiTouchGesture = false;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length > 1) _multiTouchGesture = true;
    if (_touches.length == 2) _trackpadScroll.reset();
    _pinchStart = _touches.length == 2
        ? (_touches.values.first - _touches.values.last).distance : null;
    _pinching = false;
    if (_touches.length == 3) {
      _swipeX = 0;
      _swipeSent = false;
    }
  }

  void _touchMove(PointerMoveEvent e) {
    final before = _touches[e.pointer];
    if (before == null) return;
    _touches[e.pointer] = e.localPosition;
    final delta = e.localPosition - before;
    if (_touches.length == 1) {
      queueMovement(delta);
    } else if (_touches.length == 2) {
      final distance = (_touches.values.first - _touches.values.last).distance;
      _pinchStart ??= distance;
      if ((distance - _pinchStart!).abs() >= 40) {
        _pinching = true;
        unawaited(command('key', {'key': _shortcut(
            distance > _pinchStart! ? 'equal' : 'minus')}));
        _pinchStart = distance;
      }
      if (!_pinching) {
        // One wheel step per deliberate 24px centroid movement.
        // Divide by two because both fingers contribute pointer events.
        final ticks = _trackpadScroll.add(delta.dy / 2);
        if (ticks != 0) {
          _pendingScroll += ticks;
          _scheduleScroll();
        }
      }
    } else if (_touches.length >= 3 && !_swipeSent) {
      _swipeX += delta.dx;
      if (_swipeX.abs() >= 115) {
        _swipeSent = true;
        unawaited(command('key', {'key': _macShortcuts
            ? (_swipeX > 0 ? 'cmd+tab' : 'shift+cmd+tab')
            : (_swipeX > 0 ? 'alt+tab' : 'shift+alt+tab')}));
      }
    }
  }

  void _touchUp(PointerEvent e) {
    _touches.remove(e.pointer);
    if (_touches.length < 2) {
      _pinchStart = null;
      _pinching = false;
      _trackpadScroll.reset();
    }
    if (_touches.length < 3) _swipeX = 0;
  }

  String _shortcut(String key) =>
      '${_macShortcuts ? 'cmd' : 'ctrl'}+$key';

  void _scheduleScroll() {
    if (_scrollTimer != null || _scrollInFlight || !agent.configured) return;
    _scrollTimer = Timer(const Duration(milliseconds: 20), _flushScroll);
  }

  Future<void> _flushScroll() async {
    _scrollTimer = null;
    if (!agent.configured || _scrollInFlight) return;
    final ticks = _pendingScroll.clamp(-8, 8).toInt();
    if (ticks == 0) return;
    _pendingScroll -= ticks;
    _scrollInFlight = true;
    try {
      await command('scroll', {'dy': ticks});
    } finally {
      _scrollInFlight = false;
      if (_pendingScroll != 0) _scheduleScroll();
    }
  }

  // Only by explicit tap; sends text into the focused desktop app, not the OS clipboard.
  Future<void> typePhoneClipboard() async {
    try {
      final value = (await Clipboard.getData('text/plain'))?.text;
      if (value == null || value.isEmpty) {
        if (mounted) setState(() => status = 'Phone clipboard has no text.');
        return;
      }
      for (final chunk in clipboardChunks(value)) {
        await agent.send('text', {'text': chunk});
      }
      if (mounted) {
        setState(() =>
            status = 'Typed phone clipboard into the active computer window.');
      }
    } catch (error) {
      _handleRemoteFailure(error);
    }
  }
  double _pendingMoveX = 0;
  double _pendingMoveY = 0;
  bool _movementInFlight = false;
  Timer? _movementTimer;

  // Preserve all touch motion while sending only one network movement at a time.
  void queueMovement(Offset delta) {
    _pendingMoveX += delta.dx * mouseSensitivity;
    _pendingMoveY += delta.dy * mouseSensitivity;
    _scheduleMovement();
  }

  void _scheduleMovement() {
    if (_movementTimer != null || _movementInFlight || !agent.configured) return;
    _movementTimer = Timer(const Duration(milliseconds: 12), _flushMovement);
  }

  Future<void> _flushMovement() async {
    _movementTimer = null;
    if (!agent.configured || _movementInFlight) return;
    final dx = _pendingMoveX.truncate().clamp(-300, 300);
    final dy = _pendingMoveY.truncate().clamp(-300, 300);
    if (dx == 0 && dy == 0) return;
    _pendingMoveX -= dx;
    _pendingMoveY -= dy;
    _movementInFlight = true;
    try {
      await command('move', {'dx': dx, 'dy': dy});
    } finally {
      _movementInFlight = false;
      if (_pendingMoveX.abs() >= 1 || _pendingMoveY.abs() >= 1) {
        _scheduleMovement();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _remoteRouteObserver.unsubscribe(this);
    _heartbeatTimer?.cancel();
    final listener = _announcementSubscription;
    if (listener != null) unawaited(listener.cancel());
    _announcementSocket?.close();
    _immersiveDockTimer?.cancel();
    host.dispose(); token.dispose(); pin.dispose(); typing.dispose();
    _movementTimer?.cancel();
    _scrollTimer?.cancel();
    _stopScreen();
    agent.disconnect();
    super.dispose();
  }

  Future<void> command(String type, [Map<String, Object> data = const {}]) async {
    try {
      await agent.send(type, data);
      if ((type == 'click' || type == 'tap' || type == 'scroll') &&
          _viewingScreen && _remoteLayout.visualMode == 'snapshot') {
        // The input has reached the agent before requesting the next frame.
        unawaited(Future<void>.delayed(const Duration(milliseconds: 120),
            _refreshScreenshot));
      }
      if ((_connectionLost || _agentInputDenied) && mounted) {
        setState(() {
          _connectionLost = false;
          _agentInputDenied = false;
          _connectionTechnical = null;
          status = 'Connected to ${host.text.trim()}';
        });
      }
      if (_haptics && (type == 'click' || type == 'key')) {
        unawaited(HapticFeedback.selectionClick());
      }
    } catch (e) {
      _handleRemoteFailure(e);
    }
  }

  Future<bool> connect({String? existingId, String? deviceId}) async {
    _stopScreen();
    try {
      if (mounted) {
        setState(() => _remoteLayout = const RemoteLayoutSettings());
      }
      // Reuse the cached Ed25519 phone identity on saved reconnects.
      final phone = await _phoneIdentity();
      agent.configure(host.text, token.text, pin.text,
        identity: deviceId != null && deviceId.isNotEmpty ? phone : null,
        deviceId: deviceId != null && deviceId.isNotEmpty ? deviceId : null);
      // One authenticated /api/info request replaces the separate ping +
      // version round trip on modern agents. Fall back to ping for legacy
      // agents that lack /api/info.
      String? currentAgent = await agent.agentVersion();
      if (currentAgent == null) {
        await agent.send('ping');
      }
      // Upgrade legacy token pairing to a device-specific signed identity.
      var enrolledId = deviceId ?? '';
      if (enrolledId.isEmpty) {
        try {
          enrolledId = await agent.enrollPhone(phone, 'Phone');
          agent.usePhoneKey(phone, enrolledId);
          await agent.send('ping');
        } catch (_) {
          // Older agents still accept legacy token pairing until upgraded.
          agent.configure(host.text, token.text, pin.text);
          await agent.send('ping');
          enrolledId = '';
        }
      }
      currentAgent ??= await agent.agentVersion();
      String? verifiedName = agent.reportedHostname;
      // Older agents do not yet report hostname; reverse DNS is only a
      // display hint after a successful authenticated, TLS-pinned ping.
      if (verifiedName == null && existingId == null) {
        try {
          final ip = InternetAddress(host.text.trim());
          final reverse = await ip.reverse()
              .timeout(const Duration(milliseconds: 750));
          if (reverse.host != host.text.trim() &&
              RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$')
                  .hasMatch(reverse.host)) {
            verifiedName = reverse.host;
          }
        } catch (_) {}
      }
      _connectedPlatform = agent.reportedPlatform ?? _connectedPlatform;
      if (_connectedPlatform == 'windows' || _connectedPlatform == 'linux') {
        _macShortcuts = false;
      }
      if (verifiedName != null) discoveredName = verifiedName;
      if (mounted) {
        setState(() {
        status = 'Connected to ${host.text.trim()}';
        _connectionLost = false;
        _agentInputDenied = false;
        _connectionTechnical = null;
        connectedAgentVersion = currentAgent;
        if (existingId != null && currentAgent != null) {
          _savedAgentVersions[existingId] = currentAgent;
        }
        availableAgentVersion = currentAgent != null &&
                (_latestAgentByPlatform[_connectedPlatform] ??
                    _latestReleaseVersion) != null &&
                newerThan((_latestAgentByPlatform[_connectedPlatform] ??
                    _latestReleaseVersion)!, currentAgent)
            ? (_latestAgentByPlatform[_connectedPlatform] ?? _latestReleaseVersion)
            : null;
        });
      }
      // Persist only after certificate pin verification and authenticated ping.
      try {
        final byId = savedComputers.where((d) => d.id == existingId);
        final normalizedPin = pin.text.replaceAll(
            RegExp(r'[^a-fA-F0-9]'), '').toUpperCase();
        final byPin = savedComputers.where(
            (d) => d.fingerprint.toUpperCase() == normalizedPin);
        final byHost = savedComputers.where(
            (d) => d.host == host.text.trim());
        final existing = byId.isNotEmpty ? byId.first
            : byPin.isNotEmpty ? byPin.first
            : byHost.isNotEmpty ? byHost.first : null;
        final discovered = nearbyComputers.where((d) => d.host == host.text.trim());
        final location = _detectedLocation ?? existing?.location ?? 'other';
        final device = SavedComputer(
          id: existingId ?? existing?.id ?? SavedComputer.newId(),
          name: existing?.customName == true
              ? existing!.name
              : verifiedName ?? discoveredName ?? existing?.name ?? host.text.trim(),
          host: host.text.trim(),
          token: enrolledId.isEmpty ? token.text.trim() : '',
          deviceId: enrolledId,
          fingerprint: pin.text.replaceAll(RegExp(r'[^a-fA-F0-9]'), '').toUpperCase(),
          platform: agent.reportedPlatform ?? (discovered.isEmpty
              ? (_connectedPlatform ?? existing?.platform ?? 'computer')
              : discovered.first.platform),
          location: location,
          customName: existing?.customName ?? false,
          macAddress: agent.reportedMacAddress ?? existing?.macAddress ?? '',
        );
        // For an already-saved, certificate-verified computer, show the
        // remote immediately. Secure-storage writes and layout restore can
        // finish asynchronously, without holding up one-tap launching.
        if (existingId != null && existing != null) {
          if (mounted) {
            setState(() {
              _online[device.id] = true;
            });
          }
          unawaited(() async {
            try {
              final updated = await deviceStore.upsert(device);
              if (mounted) setState(() => savedComputers = updated);
            } catch (_) {
              // Saved pairing remains available even if its display metadata
              // could not be refreshed in secure storage.
            }
          }());
        } else {
          final updated = await deviceStore.upsert(device);
          if (mounted) {
            setState(() {
              savedComputers = updated;
              _online[device.id] = true;
            });
          }
        }
        unawaited(_loadLayoutForHost(host.text.trim()));
        // Refresh this OS's agent-only feed after the authenticated
        // connection identifies its real platform. Mobile app versions
        // remain governed by the separate full AltStore release.
        unawaited(checkForUpdates(agentPlatform: device.platform));
        return true;
      } catch (_) {
        if (mounted) {
          setState(() =>
              status = 'Connected, but secure storage could not save this pairing.');
        }
        return false;
      }
    } catch (e) {
      agent.disconnect();
      if (mounted) setState(() => status = '$e');
      return false;
    }
  }

  Widget keyButton(String label, String key, {double? width}) =>
      SizedBox(width: width, child: OutlinedButton(
        onPressed: agent.configured && !_connectionLost
            ? () => command('key', {'key': key}) : null,
        child: Text(label, textAlign: TextAlign.center),
      ));


  Future<void> _loadLayoutForHost(String expectedHost) async {
    final loaded = await remoteLayoutStore.read(expectedHost);
    if (mounted && agent.configured && host.text.trim() == expectedHost) {
      setState(() => _remoteLayout = loaded);
      _syncScreen();
    }
  }

  void _setLayout(RemoteLayoutSettings next) {
    final visualChanged = _remoteLayout.visualMode != next.visualMode ||
        _remoteLayout.mediaMode != next.mediaMode ||
        _remoteLayout.presentationMode != next.presentationMode;
    final previousPreview = !_remoteLayout.mediaMode &&
        !_remoteLayout.presentationMode &&
        _remoteLayout.visualMode != 'trackpad';
    final nextPreview = !next.mediaMode && !next.presentationMode &&
        next.visualMode != 'trackpad';
    setState(() => _remoteLayout = next);
    if (visualChanged) {
      _syncScreen(preserveFrame: previousPreview && nextPreview);
    }
    unawaited(_persistLayout(host.text.trim(), next));
  }

  Future<void> _persistLayout(
      String computer, RemoteLayoutSettings value) async {
    if (computer.isEmpty) return;
    try {
      await remoteLayoutStore.write(computer, value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Unable to save control preferences on this phone.'),
        ));
      }
    }
  }

  RemoteLayoutSettings _changedLayout({
    bool? trackpad,
    bool? arrows,
    bool? more,
    bool? presenting,
    bool? mediaMode,
    String? mediaService,
    String? visualMode,
    String? presentationApp,
    List<String>? sections,
    List<String>? quick,
  }) => RemoteLayoutSettings(
    trackpadExpanded: trackpad ?? _remoteLayout.trackpadExpanded,
    arrowsExpanded: arrows ?? _remoteLayout.arrowsExpanded,
    moreExpanded: more ?? _remoteLayout.moreExpanded,
    presentationMode: presenting ?? _remoteLayout.presentationMode,
    mediaMode: mediaMode ?? _remoteLayout.mediaMode,
    mediaService: mediaService ?? _remoteLayout.mediaService,
    visualMode: visualMode ?? _remoteLayout.visualMode,
    presentationApp: presentationApp ?? _remoteLayout.presentationApp,
    expandedSections: sections ?? _remoteLayout.expandedSections,
    quickKeys: quick ?? _remoteLayout.quickKeys,
  );

  void _toggleMoreSection(String id) {
    final enabled = _remoteLayout.expandedSections.toSet();
    if (!enabled.add(id)) enabled.remove(id);
    _setLayout(_changedLayout(sections: enabled.toList()));
  }

  void _handleRemoteFailure(Object error) {
    if (!mounted) return;
    final disconnected = error is SocketException ||
        error is TimeoutException ||
        error is HandshakeException ||
        error is HttpException;
    setState(() {
      if (disconnected) {
        _stopScreen();
        _connectionLost = true;
        _connectionTechnical = error.toString();
        status = 'Connection lost';
        _pendingMoveX = 0;
        _pendingMoveY = 0;
        _pendingScroll = 0;
        _touches.clear();
      } else if (isMacAccessibilityError(error)) {
        _agentInputDenied = true;
        status = 'Mac is online but Accessibility permission blocks input.';
      } else {
        status = 'Remote command failed. Check the computer connection.';
      }
    });
  }

  Future<void> _retryRemoteConnection() async {
    if (_retryingConnection || !agent.configured) return;
    setState(() => _retryingConnection = true);
    try {
      await agent.send('ping');
      if (mounted) {
        setState(() {
          _connectionLost = false;
          _connectionTechnical = null;
          status = 'Connected to ${host.text.trim()}';
        });
      }
    } catch (error) {
      _handleRemoteFailure(error);
    } finally {
      if (mounted) setState(() => _retryingConnection = false);
    }
  }

  String _quickKeyCommand(String id) {
    if (RegExp(r'^f(?:[1-9]|1[0-2])$').hasMatch(id)) return id;
    switch (id) {
      case 'escape': return 'Escape';
      case 'tab': return 'Tab';
      case 'enter': return 'Return';
      case 'backspace': return 'BackSpace';
      case 'up': return 'Up';
      case 'down': return 'Down';
      case 'left': return 'Left';
      case 'right': return 'Right';
      case 'copy': return _shortcut('c');
      case 'paste': return _shortcut('v');
      case 'selectAll': return _shortcut('a');
      case 'undo': return _shortcut('z');
      case 'find': return _shortcut('f');
      case 'newTab': return _shortcut('t');
      case 'switchApp': return _macShortcuts ? 'cmd+tab' : 'alt+tab';
      case 'home': return 'home';
      case 'end': return 'end';
      case 'pageUp': return 'pageup';
      case 'pageDown': return 'pagedown';
      case 'volumeDown': return 'XF86AudioLowerVolume';
      case 'mute': return 'XF86AudioMute';
      case 'volumeUp': return 'XF86AudioRaiseVolume';
      default: throw ArgumentError.value(id, 'id', 'Unknown remote control');
    }
  }

  Widget _quickKeyButton(String id) =>
      keyButton(remoteQuickKeyLabels[id]!, _quickKeyCommand(id));

  Future<void> _customizeQuickKeys() async {
    final chosen = _remoteLayout.quickKeys.toList();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) => SafeArea(child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(children: [
              Row(children: [
                Expanded(child: Text('Customize quick keys',
                    style: Theme.of(context).textTheme.titleLarge)),
                TextButton(
                  onPressed: () => Navigator.pop(context, chosen),
                  child: const Text('Save'),
                ),
              ]),
              const Text('Choose visible buttons and move them up or down '
                  'to set the order. These settings are saved per computer.'),
              const SizedBox(height: 8),
              Expanded(child: ListView(children: [
                if (chosen.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('No quick keys selected. Add buttons below.'),
                  ),
                for (var i = 0; i < chosen.length; i++)
                  ListTile(
                    key: ValueKey('quick-${chosen[i]}'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(remoteQuickKeyLabels[chosen[i]]!),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Move up',
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: i == 0 ? null : () => updateSheet(() {
                          final key = chosen.removeAt(i);
                          chosen.insert(i - 1, key);
                        }),
                      ),
                      IconButton(
                        tooltip: 'Move down',
                        icon: const Icon(Icons.arrow_downward),
                        onPressed: i == chosen.length - 1 ? null
                            : () => updateSheet(() {
                          final key = chosen.removeAt(i);
                          chosen.insert(i + 1, key);
                        }),
                      ),
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.close),
                        onPressed: () => updateSheet(() => chosen.removeAt(i)),
                      ),
                    ]),
                  ),
                const Divider(),
                Text('Available controls',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final entry in remoteQuickKeyLabels.entries)
                    if (!chosen.contains(entry.key))
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 18),
                        label: Text(entry.value),
                        onPressed: () => updateSheet(() => chosen.add(entry.key)),
                      ),
                ]),
              ])),
            ]),
          ),
        )),
      ),
    );
    if (result != null && mounted) {
      _setLayout(_changedLayout(quick: result));
    }
  }


  Widget _advancedSection(String id, String title, IconData icon,
      Widget content) {
    final open = _remoteLayout.expandedSections.contains(id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        trailing: Icon(open ? Icons.expand_less : Icons.expand_more),
        onTap: () => _toggleMoreSection(id),
      ),
      if (open) Padding(padding: const EdgeInsets.only(bottom: 12),
          child: content),
      const Divider(height: 1),
    ]);
  }

  Widget _arrowPad() => Column(children: [
    Center(child: _quickKeyButton('up')),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      _quickKeyButton('left'),
      const SizedBox(width: 8),
      _quickKeyButton('down'),
      const SizedBox(width: 8),
      _quickKeyButton('right'),
    ]),
  ]);

  Widget _trackpadSurface({double height = 224,
      bool immersive = false}) => GestureDetector(
    // Win the gesture arena against the enclosing ListView. A Listener
    // receives raw multi-touch pointer events but cannot stop parent scroll.
    // Pointer tracking below continues to handle movement and two-finger
    // gestures; these pan handlers deliberately do not send duplicate input.
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) {},
    onPanUpdate: (_) {},
    onTap: _connectionLost ? null : () {
      if (!_multiTouchGesture) unawaited(command('click', {'button': 'left'}));
    },
    onDoubleTap: _connectionLost ? null : () {
      if (!_multiTouchGesture) unawaited(command('click', {'button': 'double'}));
    },
    onLongPress: _connectionLost ? null : () {
      if (!_multiTouchGesture) unawaited(command('click', {'button': 'right'}));
    },
    child: Listener(
      onPointerDown: _connectionLost ? null : _touchDown,
      onPointerUp: _connectionLost ? null : _touchUp,
      onPointerCancel: _connectionLost ? null : _touchUp,
      onPointerMove: _connectionLost ? null : _touchMove,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(immersive ? 0 : 16),
          border: immersive ? null : Border.all(
            color: Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.25))),
        child: immersive ? null : Center(child: Icon(Icons.touch_app, size: 36,
            color: Theme.of(context).colorScheme.onPrimaryContainer
                .withValues(alpha: 0.5))),
      ),
    ),
  );

  Widget _connectionBanner() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.wifi_off_outlined),
          const SizedBox(width: 8),
          Expanded(child: Text('Connection lost',
              style: Theme.of(context).textTheme.titleMedium)),
          TextButton.icon(
            onPressed: _retryingConnection ? null : _retryRemoteConnection,
            icon: const Icon(Icons.refresh),
            label: Text(_retryingConnection ? 'Retrying…' : 'Retry'),
          ),
        ]),
        const Text('The computer agent is not responding. Check that it '
            'is running and retry.'),
        if (_connectionTechnical != null)
          ExpansionTile(
            title: const Text('Technical details'),
            tilePadding: EdgeInsets.zero,
            children: [SelectableText(_connectionTechnical!,
                style: Theme.of(context).textTheme.bodySmall)],
          ),
      ]),
    ),
  );

  List<Widget> _moreControlSections() => [
        _advancedSection('editing', 'Editing & shortcuts',
          Icons.edit_outlined, Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (final id in [
                  'copy', 'paste', 'selectAll', 'undo', 'find', 'newTab',
                  'switchApp',
                ]) _quickKeyButton(id),
              ]),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _connectionLost ? null : typePhoneClipboard,
                icon: const Icon(Icons.content_paste_go),
                label: const Text('Type phone clipboard'),
              ),
              // Clipboard action is intentionally explicit. Technical detail
              // belongs in Help, not the main remote-control surface.
            ],
          ),
        ),
        _advancedSection('extended', 'Extended keyboard',
          Icons.keyboard_alt_outlined, Wrap(
            spacing: 8, runSpacing: 4, children: [
              for (final id in ['home', 'end', 'pageUp', 'pageDown'])
                _quickKeyButton(id),
              for (var f = 1; f <= 12; f++) keyButton('F$f', 'f$f'),
            ],
          ),
        ),
        _advancedSection('volume', 'Volume & media',
          Icons.volume_up_outlined, Wrap(
            spacing: 8, runSpacing: 4, children: [
              for (final id in ['volumeDown', 'mute', 'volumeUp'])
                _quickKeyButton(id),
            ],
          ),
        ),
        _advancedSection('power', 'Power',
          Icons.power_settings_new_outlined, Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              OutlinedButton.icon(
                onPressed: agent.shutdownEnabled ? confirmShutdown : null,
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Shut down computer'),
              ),
              if (!agent.shutdownEnabled)
                const Text('Shutdown is not enabled on this computer.'),
            ],
          ),
        ),
        _advancedSection('preferences', 'Remote preferences',
          Icons.settings_outlined, Column(children: [
            Row(children: [
              Text('Pointer: ${mouseSensitivity.toStringAsFixed(1)}×'),
              Expanded(child: Slider(
                value: mouseSensitivity, min: 1.0, max: 8.0, divisions: 28,
                onChanged: (value) =>
                    setState(() => mouseSensitivity = value),
              )),
            ]),
            if (_connectedPlatform != 'linux' &&
                _connectedPlatform != 'windows')
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mac shortcuts (⌘)'),
                value: _macShortcuts,
                onChanged: (value) => setState(() => _macShortcuts = value),
              ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Haptic feedback'),
              value: _haptics,
              onChanged: (value) => setState(() => _haptics = value),
            ),
          ]),
        ),
  ];


  Widget _compactModeSwitcher() => RemoteModeBar(
    key: const ValueKey('remote-mode-switcher'),
    primaryMode: _remoteLayout.presentationMode ? 'presentation'
        : _remoteLayout.mediaMode ? 'media' : 'remote',
    visualMode: VisualModePolicy.normalize(_remoteLayout.visualMode),
    captureAvailable: agent.screenCaptureSupported,
    onPrimaryMode: (mode) => _setLayout(_changedLayout(
      presenting: mode == 'presentation', mediaMode: mode == 'media')),
    // A selection inside the Remote split-button activates Remote even if
    // the user is currently on Slides or Media.
    onVisualMode: (mode) => _setLayout(_changedLayout(
        presenting: false, mediaMode: false, visualMode: mode)),
  );

  bool get _mediaIsMac => _connectedPlatform == 'darwin' ||
      (_connectedPlatform == null && _macShortcuts);

  /// Navigate the current focused browser tab. Unlike /api/media/open this
  /// does not ask the operating system to launch a new tab or browser.
  Future<void> _mediaNavigateSameTab(String url) async {
    if (!agent.configured) {
      throw StateError('Connect to a paired computer first.');
    }
    if (url.length > 256 ||
        !(url.startsWith('https://www.netflix.com/') ||
          url.startsWith('https://www.youtube.com/'))) {
      throw const FormatException('Media destination is not permitted.');
    }
    // Activate the existing default browser without creating an extra tab.
    await agent.openMedia(url.contains('netflix.com/') ? 'netflix' : 'youtube',
        '', focusOnly: true);
    await agent.send('key', {'key': _mediaIsMac ? 'cmd+l' : 'ctrl+l'});
    await agent.send('text', {'text': url});
    await agent.send('key', {'key': 'Return'});
  }

  Future<void> _mediaSearchPage(MediaService service) =>
      _mediaNavigateSameTab(MediaSearch.searchPageUrl(service));

  Future<void> _mediaExitVideo(MediaService service, String? lastSearch) async {
    // Unlike returning to /browse, browser Back preserves the page that led
    // to the video: Netflix results, a title page, or the browse list.
    // First escape HTML fullscreen, then use the browser's history shortcut.
    // Both macOS Firefox (Cmd+Left) and Windows/Linux (Alt+Left) support it.
    await agent.openMedia(service.name, '', focusOnly: true);
    await agent.send('key', {'key': 'Escape'});
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await agent.send('key',
        {'key': _mediaIsMac ? 'cmd+left' : 'alt+left'});
  }

  Future<void> _mediaFullscreen(MediaService service, bool enter) async {
    // Netflix shortcuts can go to the wrong desktop app if the browser was
    // not frontmost. Focus its existing window, without opening a new tab.
    await agent.openMedia(service.name, '', focusOnly: true);
    await Future<void>.delayed(const Duration(milliseconds: 160));
    await agent.send('key', {'key': enter ? 'f' : 'Escape'});
  }

  Future<void> _mediaProfile(MediaService service) async {
    // Generic browser control cannot inspect the selected Netflix profile
    // or click its avatar. Open the actual first-party profile management
    // chooser screen instead of /profiles/manage, which edits profiles.
    if (service == MediaService.netflix) {
      await agent.openMedia('netflix', '', focusOnly: true);
      await agent.send('key', {'key': 'Escape'});
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await _mediaNavigateSameTab(MediaSearch.profileUrl(service));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
        service == MediaService.netflix
          ? 'Netflix profile selection opened. Select a profile using '
            'Trackpad. If Netflix redirects to Browse, use the '
            'profile avatar in the top right.'
          : 'Choose your YouTube account in the browser using Trackpad.',
      )));
    }
  }

  Future<void> _mediaCloseService(MediaService service) async {
    // MediaRemote confirms first; only the focused browser tab closes.
    await agent.send('key', {'key': _mediaIsMac ? 'cmd+w' : 'ctrl+w'});
  }

  /// Explicit Open on computer must not inject Cmd+L/text/Return.
  /// If a browser is not the frontmost app, those keystrokes can trigger
  /// macOS Open dialogs in another application. Use the authenticated agent's
  /// allowlisted OS-default-browser URL opener instead. This explicit Open
  /// action may create a browser tab; same-tab navigation remains available
  /// for Search, video links, Browse history and profile selection.
  Future<void> _openMediaService(MediaService service) async {
    if (!agent.configured) {
      throw StateError('Connect to a paired computer first.');
    }
    await agent.openMedia(service.name, '');
  }

  Future<void> _searchMedia(MediaService service, String text) =>
      _mediaNavigateSameTab(text.trim().isEmpty
          ? MediaSearch.browseUrl(service) : MediaSearch.url(service, text));

  Future<void> _openMediaLink(MediaService service, String url) async {
    if (service == MediaService.netflix) {
      // A previous Netflix video can own Firefox's HTML-fullscreen focus.
      // Leave the old fullscreen player BEFORE opening a new watch URL.
      // Otherwise the first Cmd+L can be consumed by the player, so a
      // second tap appears necessary. Do not send Space/Enter/M here:
      // those are TOGGLES and can pause/mute an already playing video.
      await agent.openMedia('netflix', '', focusOnly: true);
      await agent.send('key', {'key': 'Escape'});
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await _mediaNavigateSameTab(url);
  }

  /// A short opt-in test against only the selected, TLS-pinned computer.
  /// This is not Wi-Fi link negotiation rate or ISP/internet speed.
  Future<void> _showConnectionMetrics() async {
    if (!agent.configured) return;
    bool running = false;
    ({double rttMs, double downMbps})? result;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) {
          final frame = _currentFrame;
          final bitrate = _liveRate.megabitsPerSecond;
          final fps = _liveRate.framesPerSecond;
          return AlertDialog(
            title: const Text('Local connection'),
            content: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Computer: ${discoveredName ?? host.text.trim()}'),
                const SizedBox(height: 8),
                Text('Capture: ${frame == null ? 'Waiting for frame' :
                  '${frame.width} × ${frame.height} pixels'}'),
                if (fps != null && bitrate != null) ...[
                  Text('Live: ${fps.toStringAsFixed(1)} fps · '
                      '${bitrate.toStringAsFixed(2)} Mbps JPEG'),
                ],
                const SizedBox(height: 10),
                if (running) const LinearProgressIndicator(),
                if (result != null) ...[
                  Text('API round-trip: ${result!.rttMs.toStringAsFixed(1)} ms'),
                  Text('LAN download: ${result!.downMbps.toStringAsFixed(1)} Mbps'),
                ],
                if (error != null)
                  Text(error!, style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error)),
                const SizedBox(height: 10),
                const Text('This tests only your paired computer over '
                    'encrypted local LAN. It is not your Wi-Fi link rate '
                    'or internet speed. Live uses 720p; compatible macOS '
                    'Screen Core v2 and Windows agents support an on-demand '
                    '1920 × 1080 Snapshot for zoomed detail.'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: running ? null : () => Navigator.pop(dialogContext),
                child: const Text('Close')),
              FilledButton.icon(
                key: const ValueKey('run-lan-benchmark'),
                icon: const Icon(Icons.speed),
                label: const Text('Test LAN speed'),
                onPressed: running ? null : () async {
                  updateDialog(() { running = true; error = null; });
                  try {
                    final value = await agent.benchmarkLan();
                    if (dialogContext.mounted) {
                      updateDialog(() { result = value; running = false; });
                    }
                  } catch (failure) {
                    if (dialogContext.mounted) {
                      updateDialog(() {
                        error = failure.toString().replaceFirst('Bad state: ', '');
                        running = false;
                      });
                    }
                  }
                }),
            ],
          );
        },
      ),
    );
  }

  void _requestHighDetail() {
    if (!agent.configured || _screenBusy) return;
    _requestDetailFrame = true;
    if (_remoteLayout.visualMode != 'snapshot') {
      // Pause Live intentionally; never mix differently-sized screen frames
      // or keep a 1080p encoder active during ordinary Live playback.
      _setLayout(_changedLayout(visualMode: 'snapshot',
          mediaMode: false, presenting: false));
    } else {
      unawaited(_refreshScreenshot());
    }
  }

  Widget _remoteInputSurface({double height = 224,
      bool immersive = false}) {
    final showPreview = _remoteLayout.visualMode != 'trackpad' &&
        agent.screenCaptureSupported;
    // One permanent trackpad; snapshot and live are in-place visual layers.
    return SizedBox(height: height, child: Stack(fit: StackFit.expand, children: [
      _trackpadSurface(height: height, immersive: immersive),
      if (showPreview)
        VisualSurface(
          key: const ValueKey('shared-visual-overlay'),
          height: height,
          immersive: immersive,
          frame: _currentFrame,
          live: _remoteLayout.visualMode == 'live',
          busy: _screenBusy,
          error: _screenError,
          streamDetails: _remoteLayout.visualMode == 'live' &&
                  _liveRate.framesPerSecond != null &&
                  _liveRate.megabitsPerSecond != null
              ? '${_liveRate.framesPerSecond!.toStringAsFixed(1)} fps · '
                '${_liveRate.megabitsPerSecond!.toStringAsFixed(2)} Mbps'
              : null,
          onConnectionMetrics: () => unawaited(_showConnectionMetrics()),
          onRefresh: () => unawaited(_refreshScreenshot()),
          onHighDetail: _screenBusy ? null : _requestHighDetail,
          onTap: (x, y, button) => unawaited(
              command('tap', {'x': x, 'y': y, 'button': button})),
          onClick: (button) => unawaited(
              command('click', {'button': button})),
          onMove: queueMovement,
          onScroll: (ticks) => unawaited(
              command('scroll', {'dy': ticks})),
        ),
    ]));
  }

  Widget _mediaView(bool landscape) {
    final selected = _remoteLayout.mediaService == 'netflix'
        ? MediaService.netflix : MediaService.youtube;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      MediaRemote(
        key: const ValueKey('media-remote'),
        service: selected,
        enabled: agent.configured && !_connectionLost,
        landscape: landscape,
        onServiceChanged: (service) =>
            _setLayout(_changedLayout(mediaService: service.name)),
        onKey: (key) => unawaited(command('key', {'key': key})),
        onSearch: (service, text) => _searchMedia(service, text),
        onOpenLink: _openMediaLink,
        onSearchPage: _mediaSearchPage,
        onExitVideo: _mediaExitVideo,
          onFullscreen: _mediaFullscreen,
        onProfile: _mediaProfile,
        onCloseService: _mediaCloseService,
        onOpenService: _openMediaService,
      ),
      const SizedBox(height: 12),
      Text('Mouse and keyboard',
          style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      _trackpadSurface(height: landscape ? 100 : 140),
      const SizedBox(height: 8),
      _landscapeTyping(),
    ]);
  }

  Widget _presentationView(bool landscape) {
    final isMac = _connectedPlatform == 'darwin' ||
        (_connectedPlatform == null && _macShortcuts);
    final selected = PresentationApp.values.firstWhere(
      (candidate) => candidate.name == _remoteLayout.presentationApp,
      orElse: () => PresentationApp.powerPoint,
    );
    final app = !isMac && selected == PresentationApp.keynote
        ? PresentationApp.powerPoint : selected;
    return PresentationControls(
      key: const ValueKey('presentation-remote'),
      app: app,
      isMac: isMac,
      enabled: agent.configured && !_connectionLost,
      landscape: landscape,
      onAppChanged: (selection) => _setLayout(
        _changedLayout(presentationApp: selection.name),
      ),
      onKey: (key) => unawaited(command('key', {'key': key})),
    );
  }


  // Landscape keeps the input surface immersive in every control mode.
  // Secondary buttons live in a sheet instead of splitting the screen.
  Future<void> _showLandscapeControls() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 840),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refreshSheet) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .72,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Text(_remoteLayout.presentationMode ? 'Presentation controls'
                  : _remoteLayout.mediaMode ? 'Media controls'
                  : 'Remote controls',
                style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 16),
              if (_remoteLayout.presentationMode) _presentationView(false),
              if (_remoteLayout.mediaMode)
                MediaRemote(
                  service: _remoteLayout.mediaService == 'netflix'
                      ? MediaService.netflix : MediaService.youtube,
                  enabled: agent.configured && !_connectionLost,
                  landscape: false,
                  onServiceChanged: (value) {
                    _setLayout(_changedLayout(mediaService: value.name));
                    refreshSheet(() {});
                  },
                  onKey: (key) => unawaited(command('key', {'key': key})),
                  onSearch: _searchMedia,
                  onOpenLink: _openMediaLink,
                  onSearchPage: _mediaSearchPage,
                  onExitVideo: _mediaExitVideo,
          onFullscreen: _mediaFullscreen,
                  onProfile: _mediaProfile,
                  onCloseService: _mediaCloseService,
                  onOpenService: _openMediaService,
                ),
              const SizedBox(height: 12),
              _landscapeTyping(),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Text('Quick keys',
                  style: Theme.of(sheetContext).textTheme.titleSmall)),
                TextButton(
                  onPressed: _customizeQuickKeys,
                  child: const Text('Customize')),
              ]),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final id in _remoteLayout.quickKeys) _quickKeyButton(id),
              ]),
              const SizedBox(height: 16),
              _arrowPad(),
              const SizedBox(height: 8),
              ..._moreControlSections(),
            ],
          ),
        ),
      )),
    );
  }

  // Full-screen touch surface with a tiny persistent entry point. The
  // floating dock auto-dismisses and never covers the full screen width.
  Widget _landscapeImmersive() => LayoutBuilder(
    builder: (context, limits) {
      final mode = _remoteLayout.presentationMode ? 'presentation'
          : _remoteLayout.mediaMode ? 'media' : 'remote';
      final visual = VisualModePolicy.normalize(_remoteLayout.visualMode);
      final label = discoveredName ?? host.text.trim();
      final scheme = Theme.of(context).colorScheme;
      return Stack(fit: StackFit.expand, children: [
        if (mode == 'remote')
          _remoteInputSurface(height: limits.maxHeight, immersive: true)
        else
          _trackpadSurface(height: limits.maxHeight, immersive: true),
        if (_connectionLost)
          Positioned(left: 16, right: 16, top: 56,
            child: _connectionBanner()),
        if (_immersiveDockVisible)
          Positioned(top: 8, right: 56,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (limits.maxWidth - 76).clamp(160, 570).toDouble()),
              child: Material(
                key: const ValueKey('immersive-controls-dock'),
                color: scheme.surface.withValues(alpha: .92),
                elevation: 2,
                borderRadius: BorderRadius.circular(14),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: 'Navigation',
                      icon: const Icon(Icons.menu, size: 20),
                      onPressed: () {
                        _hideImmersiveDock();
                        _scaffoldKey.currentState?.openDrawer();
                      }),
                    Tooltip(message: label,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 110),
                        child: Text(label, maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall))),
                    PopupMenuButton<String>(
                      tooltip: 'Remote, Slides, Media',
                      initialValue: mode,
                      onSelected: (selection) {
                        _setLayout(_changedLayout(
                          presenting: selection == 'presentation',
                          mediaMode: selection == 'media'));
                        _hideImmersiveDock();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'remote',
                            child: Text('Remote')),
                        PopupMenuItem(value: 'presentation',
                            child: Text('Slides')),
                        PopupMenuItem(value: 'media', child: Text('Media')),
                      ],
                      icon: Icon(mode == 'remote' ? Icons.mouse_outlined
                          : mode == 'media' ? Icons.smart_display_outlined
                          : Icons.slideshow_outlined),
                    ),
                    if (mode == 'remote') PopupMenuButton<String>(
                      tooltip: 'Trackpad, Snapshot, Live',
                      initialValue: visual,
                      onSelected: (selection) {
                        _setLayout(_changedLayout(visualMode: selection));
                        _hideImmersiveDock();
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'trackpad',
                            child: Text('Trackpad')),
                        PopupMenuItem(value: 'snapshot',
                            enabled: agent.screenCaptureSupported,
                            child: const Text('Snapshot')),
                        PopupMenuItem(value: 'live',
                            enabled: agent.screenCaptureSupported,
                            child: const Text('Live')),
                      ],
                      icon: Icon(visual == 'trackpad' ? Icons.mouse_outlined
                          : visual == 'snapshot' ? Icons.photo_outlined
                          : Icons.live_tv_outlined),
                    ),
                    if (mode == 'remote' && visual == 'snapshot')
                      IconButton(
                        tooltip: 'Refresh screenshot',
                        onPressed: _screenBusy ? null :
                            () => unawaited(_refreshScreenshot()),
                        icon: const Icon(Icons.refresh)),
                    IconButton(
                      tooltip: 'Keyboard and controls',
                      onPressed: () {
                        _hideImmersiveDock();
                        unawaited(_showLandscapeControls());
                      },
                      icon: const Icon(Icons.keyboard_outlined)),
                    IconButton(
                      key: const ValueKey('immersive-back-to-devices'),
                      tooltip: 'Back to My Devices',
                      onPressed: _backToMyDevices,
                      icon: const Icon(Icons.arrow_back),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        Positioned(top: 8, right: 8,
          child: Material(
            color: scheme.surface.withValues(alpha: .78),
            borderRadius: BorderRadius.circular(12),
            child: IconButton(
              key: const ValueKey('immersive-controls-toggle'),
              tooltip: _immersiveDockVisible
                  ? 'Hide remote controls' : 'Show remote controls',
              iconSize: 20,
              constraints: const BoxConstraints(
                minWidth: 40, minHeight: 40),
              onPressed: _immersiveDockVisible
                  ? _hideImmersiveDock : _showImmersiveDock,
              icon: Icon(_immersiveDockVisible ?
                  Icons.close : Icons.tune_outlined),
            ),
          ),
        ),
      ]);
    },
  );


  Widget _landscapeTyping() => TextField(
    controller: typing,
    enabled: !_connectionLost,
    autocorrect: false,
    enableSuggestions: false,
    decoration: const InputDecoration(
      isDense: true,
      prefixIcon: Icon(Icons.keyboard_outlined),
      labelText: 'Type on computer',
    ),
    onChanged: (text) {
      if (text.isNotEmpty) {
        unawaited(command('text', {'text': text}));
        typing.clear();
      }
    },
  );

  void _backToMyDevices() {
    _stopScreen();
    agent.disconnect();
    setState(() {
      _connectionLost = false;
      _agentInputDenied = false;
      _connectionTechnical = null;
      status = 'Select a saved device to connect.';
    });
    unawaited(_refreshHeartbeats());
  }

  Widget _connectedControls() {
    final colors = Theme.of(context).colorScheme;
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(Icons.circle, color: _connectionLost ? colors.error
            : colors.primary, size: 11),
        const SizedBox(width: 8),
        Expanded(child: Text(discoveredName ?? host.text.trim(),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium)),

      ]),
      if (_connectionLost) _connectionBanner(),
      if (_agentInputDenied && !_connectionLost)
        Card(
          key: const ValueKey('mac-accessibility-warning'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mac input permission required',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                const Text('Your Mac is online, but macOS is blocking '
                    'mouse and keyboard control. On the Mac, open '
                    'System Settings → Privacy & Security → Accessibility, '
                    'allow taptether-input-core, then restart TapTether.'),
              ],
            ),
          ),
        ),
      _compactModeSwitcher(),
      if (_remoteLayout.presentationMode) _presentationView(landscape),
      if (_remoteLayout.mediaMode) _mediaView(landscape),
      if (!_remoteLayout.presentationMode && !_remoteLayout.mediaMode &&
          !landscape) ...[
      const SizedBox(height: 8),
      _remoteInputSurface(),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: OutlinedButton(
          onPressed: _connectionLost ? null :
              () => command('click', {'button': 'left'}),
          child: const Text('Left click'),
        )),
        const SizedBox(width: 8),
        Expanded(child: OutlinedButton(
          onPressed: _connectionLost ? null :
              () => command('click', {'button': 'right'}),
          child: const Text('Right click'),
        )),
      ]),
      const SizedBox(height: 8),
      TextField(
        controller: typing,
        enabled: !_connectionLost,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          isDense: true,
          prefixIcon: Icon(Icons.keyboard_outlined),
          labelText: 'Type on computer',
        ),
        onChanged: (text) {
          if (text.isNotEmpty) {
            unawaited(command('text', {'text': text}));
            typing.clear();
          }
        },
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: Text('Shortcuts',
            style: Theme.of(context).textTheme.titleSmall)),
        TextButton.icon(
          onPressed: _customizeQuickKeys,
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('Customize'),
        ),
      ]),
      if (_remoteLayout.quickKeys.isEmpty)
        const Text('Choose shortcuts using Customize.')
      else
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final id in _remoteLayout.quickKeys) _quickKeyButton(id),
        ]),
      TextButton.icon(
        key: const ValueKey('arrow-keys-toggle'),
        onPressed: () => _setLayout(_changedLayout(
          arrows: !_remoteLayout.arrowsExpanded)),
        icon: Icon(_remoteLayout.arrowsExpanded
            ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down),
        label: Text(_remoteLayout.arrowsExpanded
            ? 'Hide arrow keys' : 'Show arrow keys'),
      ),
      if (_remoteLayout.arrowsExpanded) _arrowPad(),
      const Divider(),
      OutlinedButton.icon(
        key: const ValueKey('more-controls-toggle'),
        onPressed: () => _setLayout(_changedLayout(
          more: !_remoteLayout.moreExpanded)),
        icon: Icon(_remoteLayout.moreExpanded
            ? Icons.expand_less : Icons.expand_more),
        label: Text(_remoteLayout.moreExpanded
            ? 'Hide more controls' : 'More controls'),
      ),
      if (_remoteLayout.moreExpanded) ..._moreControlSections(),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    // Keep the dashboard visible until a tapped saved device has completed
    // TLS pin verification and authenticated its control session.
    final connected = agent.configured && _connectingDeviceId == null;
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      key: _scaffoldKey,
      drawer: appDrawer(),
      appBar: connected && landscape ? null : AppBar(
        leading: IconButton(
          key: ValueKey(connected ? 'back-to-devices' : 'open-navigation'),
          tooltip: connected ? 'Back to My Devices' : 'Open navigation',
          icon: Icon(connected ? Icons.arrow_back : Icons.menu),
          onPressed: connected
              ? _backToMyDevices
              : () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: Text(connected ? (discoveredName ?? 'Remote') : 'TapTether',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: connected && landscape
          ? SafeArea(child: _landscapeImmersive())
          : SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
        if (!connected) ...[
          Text('Your devices. Your control. Your network.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w500,
              )),
          const SizedBox(height: 12),
        ],
        if (!connected) updateNotices(),
        if (!connected) ...[
          deviceDashboard(),
          if (_showPairForm) ...[
          const Text('Pair with a computer agent', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('For first-time pairing, enter the token and TLS SHA-256 fingerprint from your computer. Verified devices are saved securely on this phone.'),
          const SizedBox(height: 12),
          TextField(controller: host, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Computer LAN IP (e.g. 192.168.1.10)', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: token, obscureText: true, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Agent pairing token', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(controller: pin, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Certificate SHA-256 fingerprint', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: () async { await connect(); }, icon: const Icon(Icons.lan), label: const Text('Connect locally')),
          ],
        ] else ...[
          _connectedControls(),
        ],
        const SizedBox(height: 16),
        if (!connected) ...[
          if ((_showPairForm || _showQuickActions || savedComputers.isEmpty) &&
              status.isNotEmpty && status != 'Not connected' &&
              status != 'Select a saved device to connect.') ...[
            Text(status, style: TextStyle(fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 12),
          ],
          Center(child: Text('TapTether v$installedVersion',
            style: TextStyle(fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant))),
        ],
      ])),
    );
  }
}
