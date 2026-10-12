import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'computer_store.dart';
import 'discovery.dart';
import 'phone_identity.dart';
import 'qr_pairing.dart';
import 'ssh_provisioner.dart';
import 'ssh_key_screen.dart';
import 'phone_ssh_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const TapTetherApp());

class TapTetherApp extends StatelessWidget {
  const TapTetherApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TapTether',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF57E6C2),
          scaffoldBackgroundColor: const Color(0xFF102326),
        ),
        home: const RemoteScreen(),
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
    final sshHost = TextEditingController(text: host.text);
    final user = TextEditingController();
    final sshPassword = TextEditingController();
    final sudoPassword = TextEditingController();
    final sshFingerprint = TextEditingController();
    var loginMethod = SshLoginMethod.password;
    var authorizeKey = false;
    final hasKey = await PhoneSshKeyStore().exists;
    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
        title: const Text('Install Ubuntu agent over SSH'),
        content: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Verify the SSH host fingerprint independently on '
                'your Ubuntu computer before proceeding. SSH must be enabled '
                'and the user must have sudo privileges.'),
            TextField(controller: sshHost,
              decoration: const InputDecoration(labelText: 'Ubuntu LAN IP')),
            TextField(controller: user,
              decoration: const InputDecoration(labelText: 'SSH username')),
            TextField(controller: sshFingerprint, autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Verified SSH host SHA256: fingerprint')),
            const SizedBox(height: 12),
            DropdownButtonFormField<SshLoginMethod>(
              initialValue: loginMethod,
              decoration: const InputDecoration(labelText: 'SSH login method'),
              items: [
                const DropdownMenuItem(
                    value: SshLoginMethod.password, child: Text('SSH password')),
                DropdownMenuItem(
                    value: SshLoginMethod.phoneKey,
                    enabled: hasKey, child: const Text('TapTether SSH key')),
              ],
              onChanged: (value) {
                if (value != null) setDialogState(() => loginMethod = value);
              },
            ),
            if (loginMethod == SshLoginMethod.password)
              TextField(controller: sshPassword, obscureText: true,
                decoration: const InputDecoration(labelText: 'SSH password')),
            if (loginMethod == SshLoginMethod.password && hasKey)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: authorizeKey,
                onChanged: (v) => setDialogState(() => authorizeKey = v ?? false),
                title: const Text('Authorize this phone SSH key'),
                subtitle: const Text('Add only the public key to Ubuntu authorized_keys '
                    'after a verified password login. No private key is uploaded.'),
              ),
            if (!hasKey)
              const Text('Generate or import an SSH key under My SSH Key '
                  'to enable password-free SSH installation.'),
            TextField(controller: sudoPassword, obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Ubuntu sudo password (leave blank if passwordless)')),
            const SizedBox(height: 10),
            const Text('Verify on the computer: '
              'sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256. '
              'The SSH connection will be rejected if its host key does not match.'),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Install & pair')),
        ],
      ),
      ),
    );
    final request = approved == true
        ? SshInstallRequest(
          host: sshHost.text.trim(),
          username: user.text.trim(),
          sshPassword: sshPassword.text,
          sudoPassword: sudoPassword.text,
          hostKeyFingerprint: sshFingerprint.text.trim(),
          loginMethod: loginMethod,
          authorizePhoneKey: authorizeKey,
        )
        : null;
    sshHost.dispose();
    user.dispose();
    sshPassword.dispose();
    sudoPassword.dispose();
    sshFingerprint.dispose();
    if (request == null || !mounted) return;
    setState(() {
      installingAgent = true;
      status = 'Installing Ubuntu agent over authenticated SSH…';
    });
    try {
      final installed = await UbuntuSshProvisioner.install(request);
      if (!mounted) return;
      host.text = installed.host;
      token.text = installed.token;
      pin.text = installed.fingerprint;
      discoveredName = installed.host;
      await connect(); // Enroll phone key and save trusted device.
    } catch (e) {
      if (mounted) setState(() => status = 'SSH installation: $e');
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

  Widget deviceDashboard() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('My Devices',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      for (final device in savedComputers)
        Card(child: ListTile(
          leading: Icon(device.platform == 'darwin'
              ? Icons.laptop_mac : Icons.desktop_windows),
          title: Text(device.name),
          subtitle: Text(device.host),
          onTap: () => connectSaved(device),
          trailing: IconButton(
            tooltip: 'Forget ${device.name}',
            onPressed: () => forgetComputer(device),
            icon: const Icon(Icons.delete_outline),
          ),
        )),
      if (savedComputers.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('No paired computers yet. Pair once to save a device securely.')),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SshKeyScreen()),
          ),
          icon: const Icon(Icons.vpn_key),
          label: const Text('My SSH Key'),
        ),
        OutlinedButton.icon(
          onPressed: scanQrPairing,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan QR pairing'),
        ),
        OutlinedButton.icon(
          onPressed: installingAgent ? null : installUbuntuViaSsh,
          icon: const Icon(Icons.install_desktop),
          label: const Text('Install Ubuntu via SSH'),
        ),
      ]),
      const SizedBox(height: 6),
      OutlinedButton.icon(
        onPressed: searching ? null : searchNearby,
        icon: searching
            ? const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.radar),
        label: Text(searching ? 'Searching LAN…' : 'Find nearby computers'),
      ),
      for (final nearby in nearbyComputers)
        ListTile(
          leading: const Icon(Icons.computer),
          title: Text(nearby.name),
          subtitle: Text('${nearby.host} · ${nearby.platform} · ${nearby.version}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => selectDiscovered(nearby),
        ),
      const SizedBox(height: 18),
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
  double _scrollRemainder = 0;
  int _pendingScroll = 0;
  Timer? _scrollTimer;
  bool _scrollInFlight = false;
  double mouseSensitivity = 3.8;

  void _touchDown(PointerDownEvent e) {
    _touches[e.pointer] = e.localPosition;
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
    final ticks = _pendingScroll.clamp(-8, 8);
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
      if (utf8.encode(value).length > 4096) {
        throw const FormatException('Clipboard exceeds the 4 KB safety limit.');
      }
      var chunk = '';
      var size = 0;
      for (final rune in value.runes) {
        final character = String.fromCharCode(rune);
        final bytes = utf8.encode(character).length;
        if (size + bytes > 256) {
          await agent.send('text', {'text': chunk});
          chunk = '';
          size = 0;
        }
        chunk += character;
        size += bytes;
      }
      if (chunk.isNotEmpty) await agent.send('text', {'text': chunk});
      if (mounted) setState(() =>
          status = 'Typed phone clipboard into the active computer window.');
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

  Future<void> connect({String? existingId, String? deviceId}) async {
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
      } catch (_) {
        if (mounted) {
          setState(() =>
              status = 'Connected, but secure storage could not save this pairing.');
        }
      }
    } catch (e) {
      agent.disconnect();
      if (mounted) setState(() => status = '$e');
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
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(7),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/branding/taptether.png'),
          ),
        ),
        title: const Text('TapTether'), actions: [
        IconButton(tooltip: 'Disconnect', onPressed: connected ? () {
          agent.disconnect(); setState(() => status = 'Disconnected');
        } : null, icon: const Icon(Icons.link_off)),
      ]),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Your devices. Your control. Your network.',
            style: TextStyle(color: Color(0xFF57E6C2))),
        const SizedBox(height: 12),
        updateNotices(),
        if (!connected) ...[
          deviceDashboard(),
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
          FilledButton.icon(onPressed: connect, icon: const Icon(Icons.lan), label: const Text('Connect locally')),
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
            onTap: () => command('click', {'button': 'left'}),
            onDoubleTap: () => command('click', {'button': 'double'}),
            onLongPress: () => command('click', {'button': 'right'}),
            child: Listener(
              onPointerDown: _touchDown,
              onPointerUp: _touchUp,
              onPointerCancel: _touchUp,
              onPointerMove: _touchMove,
              child: Container(
                height: 260,
                decoration: BoxDecoration(
                  color: const Color(0xFF1B393C),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF57E6C2).withValues(alpha: 0.25))),
                child: const Center(child: Icon(Icons.touch_app, size: 50, color: Color(0xFF57E6C2))),
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
          const Text('Types up to 4 KB into the focused app. Ubuntu native input supports ASCII text. No automatic clipboard syncing.',
              style: TextStyle(fontSize: 12, color: Colors.white70)),
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
        Text(status, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        const SizedBox(height: 12),
        Center(child: Text('TapTether v$installedVersion',
          style: const TextStyle(fontSize: 12, color: Colors.white54))),
      ])),
    );
  }
}
