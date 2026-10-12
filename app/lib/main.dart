import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

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

  bool get configured => _base != null && _client != null;

  void configure(String host, String token, String fingerprint) {
    host = host.trim();
    final expected = fingerprint.replaceAll(RegExp(r'[^a-fA-F0-9]'), '').toUpperCase();
    if (expected.length != 64) {
      throw const FormatException('Enter the complete 64-character TLS SHA-256 fingerprint.');
    }
    if (token.trim().length < 20) {
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

  Future<void> send(String type, [Map<String, Object> details = const {}]) async {
    if (!configured) throw StateError('Connect to your local agent first.');
    final req = await _client!.postUrl(_base!.resolve('/api/control'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'type': type, ...details}));
    final res = await req.close().timeout(const Duration(seconds: 5));
    if (res.statusCode != 204) {
      final body = await utf8.decoder.bind(res).join();
      throw StateError('Agent response ${res.statusCode}: $body');
    }
    await res.drain<void>();
  }

  void disconnect() {
    _client?.close(force: true);
    _client = null;
    _base = null;
    _token = null;
  }
}

class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  final agent = LocalAgent();
  final host = TextEditingController();
  final token = TextEditingController();
  final pin = TextEditingController();
  final typing = TextEditingController();
  String status = 'Not connected';
  int fingers = 0;
  double mouseSensitivity = 3.8;
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
    agent.disconnect();
    super.dispose();
  }

  Future<void> command(String type, [Map<String, Object> data = const {}]) async {
    try {
      await agent.send(type, data);
    } catch (e) {
      if (mounted) setState(() => status = e.toString());
    }
  }

  Future<void> connect() async {
    try {
      agent.configure(host.text, token.text, pin.text);
      await agent.send('ping');
      if (mounted) setState(() => status = 'Connected to ${host.text.trim()}');
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
      appBar: AppBar(title: const Text('TapTether'), actions: [
        IconButton(tooltip: 'Disconnect', onPressed: connected ? () {
          agent.disconnect(); setState(() => status = 'Disconnected');
        } : null, icon: const Icon(Icons.link_off)),
      ]),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Your devices. Your control. Your network.',
            style: TextStyle(color: Color(0xFF57E6C2))),
        const SizedBox(height: 12),
        if (!connected) ...[
          const Text('Pair with a computer agent', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('Run the agent on Ubuntu and copy its LAN IP, token and certificate SHA-256 fingerprint. These credentials are kept in memory only.'),
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
          const Text('Trackpad', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const Text('Move: one finger  ·  Scroll: two fingers  ·  Tap: click  ·  Long press: right click'),
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
              onPointerDown: (_) => fingers++,
              onPointerUp: (_) => fingers = fingers > 0 ? fingers - 1 : 0,
              onPointerCancel: (_) => fingers = fingers > 0 ? fingers - 1 : 0,
              onPointerMove: (event) {
                if (fingers > 1) {
                  final dy = event.delta.dy.round();
                  if (dy != 0) unawaited(command('scroll', {'dy': dy}));
                } else {
                  queueMovement(event.delta);
                }
              },
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
            keyButton('Ctrl+C','ctrl+c'), keyButton('Ctrl+V','ctrl+v'),
            keyButton('Ctrl+L','ctrl+l'), keyButton('Alt+Tab','alt+Tab'),
          ]),
          const SizedBox(height: 8),
          const Text('System volume', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          Wrap(spacing: 8, runSpacing: 4, children: [
            keyButton('Volume −', 'XF86AudioLowerVolume'),
            keyButton('Mute', 'XF86AudioMute'),
            keyButton('Volume +', 'XF86AudioRaiseVolume'),
          ]),
        ],
        const SizedBox(height: 16),
        Text(status, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ])),
    );
  }
}
