import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'computer_store.dart';
import 'clipboard_chunks.dart';
import 'appearance.dart';
import 'app_security.dart';
import 'security_settings_screen.dart';
import 'device_manager_screen.dart';
import 'discovery.dart';
import 'phone_identity.dart';
import 'qr_pairing.dart';
import 'ssh_key_screen.dart';
import 'ubuntu_install_screen.dart';
import 'lan_scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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
  bool get shutdownEnabled => _shutdownEnabled;

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
        return null; // Compatibility with older Ubuntu agents.
      }
      final body = jsonDecode(await utf8.decoder.bind(response).join());
      if (body is Map && body['version'] is String) {
        _shutdownEnabled = body['shutdownEnabled'] == true;
        return body['version'] as String;
      }
    } catch (_) {
      // Older agent versions and offline connections still work normally.
    }
    return null;
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
  }
}

class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  final agent = LocalAgent();
  final deviceStore = ComputerStore();
  List<SavedComputer> savedComputers = [];
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
  bool _macShortcuts = false;
  bool _haptics = true;

  @override
  void initState() {
    super.initState();
    unawaited(loadInstalledVersion());
    unawaited(checkForUpdates());
    unawaited(loadComputers());
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

  Future<void> installUbuntuViaSsh() async {
    if (installingAgent) return;
    setState(() => installingAgent = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => UbuntuInstallScreen(
          initialHost: host.text,
          onInstalled: (installed) async {
            host.text = installed.host;
            token.text = installed.token;
            pin.text = installed.fingerprint;
            discoveredName = installed.host;
            // Require an authenticated TLS-pinned ping AND successful
            // persistence. An existing device record must never mask a failed
            // pairing or a failed secure-storage write.
            return connect();
          },
        )),
      );
    } finally {
      if (mounted) setState(() => installingAgent = false);
    }
  }

  Future<void> loadComputers() async {
    try {
      final devices = await deviceStore.read();
      if (mounted) setState(() => savedComputers = devices);
    } catch (_) {
      if (mounted) {
        setState(() =>
            status = 'Saved devices could not be loaded. Check secure storage permissions.');
      }
    }
  }

  Future<void> scanNetwork() async {
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) =>
          LanScanScreen(initialIp: host.text.trim())),
    );
    if (selected == null || !mounted) return;
    agent.disconnect();
    setState(() {
      host.text = selected;
      discoveredName = selected;
      _showPairForm = true;
      status = 'Selected $selected from LAN scan. Pairing credentials are still required.';
    });
  }

  Future<void> searchNearby() async {
    if (searching) return;
    setState(() {
      searching = true;
      nearbyComputers = [];
      status = 'Looking for TapTether agents on the local network…';
    });
    try {
      final result = await findNearbyDevices();
      if (!mounted) return;
      setState(() {
        nearbyComputers = result;
        status = result.isEmpty
            ? 'No agents found. Check Wi-Fi, firewall UDP 48322, or enter the address manually.'
            : 'Found ${result.length} local computer(s). Select one to pair.';
      });
    } catch (error) {
      if (mounted) {
        setState(() =>
            status = 'Discovery unavailable: $error. Enter the IP manually.');
      }
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  void selectDiscovered(DiscoveredDevice device) {
    setState(() {
      discoveredName = device.name;
      _macShortcuts = device.platform == 'darwin';
      _showPairForm = true;
      host.text = device.host;
      token.clear();
      pin.clear();
      status = 'Discovered ${device.name}. Enter its token and certificate fingerprint to verify ownership.';
    });
  }

  Future<void> connectSaved(SavedComputer device) async {
    host.text = device.host;
    token.text = device.token;
    pin.text = device.fingerprint;
    discoveredName = device.name;
    _macShortcuts = device.platform == 'darwin';
    await connect(existingId: device.id, deviceId: device.deviceId);
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

  Future<void> openDeviceManager() async {
    final addNew = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DeviceManagerScreen(
        store: deviceStore,
        onConnect: connectSaved,
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
              title: const Text('Install Ubuntu agent'),
              onTap: installingAgent ? null : () {
                Navigator.pop(context);
                installUbuntuViaSsh();
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

  Widget deviceDashboard() => Column(
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
      if (savedComputers.isEmpty)
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
        for (final device in savedComputers)
          Card(child: ListTile(
            leading: Icon(device.platform == 'darwin'
                ? Icons.laptop_mac : Icons.computer),
            title: Text(device.name, maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: Text(device.host, maxLines: 1,
                overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => connectSaved(device),
          )),
      for (final nearby in nearbyComputers)
        Card(child: ListTile(
          leading: const Icon(Icons.radar),
          title: Text(nearby.name),
          subtitle: Text('${nearby.host} · ${nearby.platform}'),
          trailing: const Icon(Icons.add_link),
          onTap: () => selectDiscovered(nearby),
        )),
      const SizedBox(height: 20),
      Text('Quick actions', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
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
          avatar: const Icon(Icons.install_desktop, size: 18),
          label: const Text('Install agent'),
          onPressed: installingAgent ? null : installUbuntuViaSsh,
        ),
      ]),
      const SizedBox(height: 14),
    ],
  );

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

  Future<void> checkForUpdates() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    try {
      // The only startup internet request checks public release metadata.
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
      if (app['version'] is! String) return;
      final latest = "${app['version']}+${app['buildVersion']}";
      final local = await PackageInfo.fromPlatform();
      final current = '${local.version}+${local.buildNumber}';
      if (!mounted) return;
      setState(() {
        _latestReleaseVersion = latest;
        availableAppVersion = newerThan(latest, current) ? latest : null;
        availableAgentVersion = connectedAgentVersion != null &&
                newerThan(latest, connectedAgentVersion!)
            ? latest : null;
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
      if (mounted) setState(() => status = e.toString());
    }
  }


  final Map<int, Offset> _touches = {};
  double? _pinchStart;
  bool _pinching = false;
  double _swipeX = 0;
  bool _swipeSent = false;
  bool _multiTouchGesture = false;
  double _scrollRemainder = 0;
  int _pendingScroll = 0;
  Timer? _scrollTimer;
  bool _scrollInFlight = false;
  double mouseSensitivity = 3.8;

  void _touchDown(PointerDownEvent e) {
    if (_touches.isEmpty) _multiTouchGesture = false;
    _touches[e.pointer] = e.localPosition;
    if (_touches.length > 1) _multiTouchGesture = true;
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
        _scrollRemainder += delta.dy / 15;
        final ticks = _scrollRemainder.truncate();
        if (ticks != 0) {
          _scrollRemainder -= ticks;
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
      _scrollRemainder = 0;
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
      if (mounted) setState(() => status = 'Clipboard typing failed: $error');
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
    host.dispose(); token.dispose(); pin.dispose(); typing.dispose();
    _movementTimer?.cancel();
    _scrollTimer?.cancel();
    agent.disconnect();
    super.dispose();
  }

  Future<void> command(String type, [Map<String, Object> data = const {}]) async {
    try {
      await agent.send(type, data);
      if (_haptics && (type == 'click' || type == 'key')) {
        unawaited(HapticFeedback.selectionClick());
      }
    } catch (e) {
      if (mounted) setState(() => status = e.toString());
    }
  }

  Future<bool> connect({String? existingId, String? deviceId}) async {
    try {
      final phone = await PhoneIdentity.loadOrCreate();
      agent.configure(host.text, token.text, pin.text,
        identity: deviceId != null && deviceId.isNotEmpty ? phone : null,
        deviceId: deviceId != null && deviceId.isNotEmpty ? deviceId : null);
      await agent.send('ping');
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
      final currentAgent = await agent.agentVersion();
      if (mounted) {
        setState(() {
        status = 'Connected to ${host.text.trim()}';
        connectedAgentVersion = currentAgent;
        availableAgentVersion = currentAgent != null &&
                _latestReleaseVersion != null &&
                newerThan(_latestReleaseVersion!, currentAgent)
            ? _latestReleaseVersion : null;
        });
      }
      // Persist only after certificate pin verification and authenticated ping.
      try {
        final matches = savedComputers.where((d) => d.host == host.text.trim());
        final existing = matches.isEmpty ? null : matches.first;
        final discovered = nearbyComputers.where((d) => d.host == host.text.trim());
        final device = SavedComputer(
          id: existingId ?? existing?.id ?? SavedComputer.newId(),
          name: discoveredName ?? existing?.name ?? host.text.trim(),
          host: host.text.trim(),
          token: enrolledId.isEmpty ? token.text.trim() : '',
          deviceId: enrolledId,
          fingerprint: pin.text.replaceAll(RegExp(r'[^a-fA-F0-9]'), '').toUpperCase(),
          platform: discovered.isEmpty
              ? (existing?.platform ?? 'computer') : discovered.first.platform,
        );
        final updated = await deviceStore.upsert(device);
        if (mounted) setState(() => savedComputers = updated);
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
        onPressed: agent.configured ? () => command('key', {'key': key}) : null,
        child: Text(label, textAlign: TextAlign.center),
      ));

  @override
  Widget build(BuildContext context) {
    final connected = agent.configured;
    return Scaffold(
      key: _scaffoldKey,
      drawer: appDrawer(),
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Open navigation',
          icon: const Icon(Icons.menu),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: const Text('TapTether'), actions: [
        IconButton(tooltip: 'Disconnect', onPressed: connected ? () {
          agent.disconnect(); setState(() => status = 'Disconnected');
        } : null, icon: const Icon(Icons.link_off)),
      ]),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Your devices. Your control. Your network.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w500,
            )),
        const SizedBox(height: 12),
        updateNotices(),
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
          OutlinedButton.icon(
            onPressed: () {
              agent.disconnect();
              setState(() => status = 'Select a device to connect.');
            },
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Switch computer'),
          ),
          const Text('Trackpad', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const Text('Move: one finger · Scroll/pinch: two fingers · Switch apps: three-finger swipe · Tap: click · Hold: right click'),
          Row(children: [
            Text('Speed: ${mouseSensitivity.toStringAsFixed(1)}×'),
            Expanded(child: Slider(
              value: mouseSensitivity,
              min: 1.0, max: 8.0, divisions: 28,
              label: '${mouseSensitivity.toStringAsFixed(1)}×',
              onChanged: (value) => setState(() => mouseSensitivity = value),
            )),
          ]),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () {
              if (!_multiTouchGesture) unawaited(command('click', {'button': 'left'}));
            },
            onDoubleTap: () {
              if (!_multiTouchGesture) unawaited(command('click', {'button': 'double'}));
            },
            onLongPress: () {
              if (!_multiTouchGesture) unawaited(command('click', {'button': 'right'}));
            },
            child: Listener(
              onPointerDown: _touchDown,
              onPointerUp: _touchUp,
              onPointerCancel: _touchUp,
              onPointerMove: _touchMove,
              child: Container(
                height: 260,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25))),
                child: Center(child: Icon(Icons.touch_app, size: 50,
                    color: Theme.of(context).colorScheme.onPrimaryContainer)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => command('click', {'button': 'left'}), child: const Text('Left click'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: () => command('click', {'button': 'right'}), child: const Text('Right click'))),
          ]),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mac shortcuts (⌘ instead of Ctrl)'),
            value: _macShortcuts,
            onChanged: (value) => setState(() => _macShortcuts = value),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Haptic feedback'),
            value: _haptics,
            onChanged: (value) => setState(() => _haptics = value),
          ),
          OutlinedButton.icon(
            onPressed: typePhoneClipboard,
            icon: const Icon(Icons.content_paste_go),
            label: const Text('Type phone clipboard on computer'),
          ),
          Text('Types up to 4 KB into the focused app. Ubuntu native input supports ASCII text. No automatic clipboard syncing.',
              style: TextStyle(fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          TextField(controller: typing, autocorrect: false, enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Type on computer', border: OutlineInputBorder()),
            onChanged: (text) {
              if (text.isNotEmpty) {
                unawaited(command('text', {'text': text}));
                typing.clear();
              }
            }),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 4, children: [
            keyButton('Esc','Escape'), keyButton('Tab','Tab'),
            keyButton('Enter','Return'), keyButton('⌫','BackSpace'),
            keyButton('↑','Up'), keyButton('↓','Down'),
            keyButton('←','Left'), keyButton('→','Right'),
            keyButton('Copy', _shortcut('c')),
            keyButton('Paste', _shortcut('v')),
            keyButton('Select all', _shortcut('a')),
            keyButton('Undo', _shortcut('z')),
            keyButton('Find', _shortcut('f')),
            keyButton('New tab', _shortcut('t')),
            keyButton('Switch app', _macShortcuts ? 'cmd+tab' : 'alt+tab'),
          ]),
          const SizedBox(height: 8),
          const Text('Extended keyboard', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          Wrap(spacing: 8, runSpacing: 4, children: [
            keyButton('Home', 'home'), keyButton('End', 'end'),
            keyButton('PgUp', 'pageup'), keyButton('PgDn', 'pagedown'),
            for (var f = 1; f <= 12; f++) keyButton('F$f', 'f$f'),
          ]),
          const SizedBox(height: 8),
          const Text('System volume', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          Wrap(spacing: 8, runSpacing: 4, children: [
            keyButton('Volume −', 'XF86AudioLowerVolume'),
            keyButton('Mute', 'XF86AudioMute'),
            keyButton('Volume +', 'XF86AudioRaiseVolume'),
          ]),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: agent.shutdownEnabled ? confirmShutdown : null,
            icon: const Icon(Icons.power_settings_new),
            label: const Text('Shut down computer'),
          ),
          if (!agent.shutdownEnabled)
            const Text('Remote shutdown disabled on computer. Enable it with taptetherctl enable-shutdown.'),

        ],
        const SizedBox(height: 16),
        Text(status, style: TextStyle(fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        Center(child: Text('TapTether v$installedVersion',
          style: TextStyle(fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant))),
      ])),
    );
  }
}
