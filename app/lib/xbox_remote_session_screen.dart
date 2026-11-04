import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'xbox_remote_play.dart';
import 'xbox_virtual_gamepad.dart';

/// Proof of concept: inputs reach the web page's Gamepad API, not an
/// independently authenticated Xbox control socket. Web policy may reject
/// virtual controllers, so the UI never claims console pairing.
class XboxRemoteSessionScreen extends StatefulWidget {
  const XboxRemoteSessionScreen({super.key, required this.host});
  final String host;

  @override
  State<XboxRemoteSessionScreen> createState() =>
      _XboxRemoteSessionScreenState();
}

class _XboxRemoteSessionScreenState extends State<XboxRemoteSessionScreen>
    with WidgetsBindingObserver {
  late final WebViewController _browser;
  bool _loading = true;
  bool _bridgeReady = false;
  String _status = 'Sign in';
  String _currentUrl = '';
  Future<void> _inputQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _browser = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          if (!mounted) return;
          setState(() {
            _loading = true;
            _bridgeReady = false;
            _status = 'Loading';
            _currentUrl = url;
          });
        },
        onPageFinished: (url) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _currentUrl = url;
          });
          unawaited(_prepareGamepad(url));
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame != true || !mounted) return;
          setState(() {
            _loading = false;
            _bridgeReady = false;
            _status = 'Unavailable';
          });
        },
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          if (uri != null &&
              (uri.scheme == 'https' || uri.scheme == 'about')) {
            return NavigationDecision.navigate;
          }
          return NavigationDecision.prevent;
        },
      ))
      ..loadRequest(XboxRemotePlayLauncher.uri);
  }

  Future<void> _prepareGamepad(String url) async {
    if (!XboxVirtualGamepad.isMicrosoftXboxPage(url)) {
      if (mounted) {
        setState(() {
          _bridgeReady = false;
          _status = 'Sign in';
        });
      }
      return;
    }
    try {
      final r = await _browser.runJavaScriptReturningResult(
          XboxVirtualGamepad.bootstrap);
      if (!mounted || _currentUrl != url) return;
      final ready = r.toString().contains('installed');
      setState(() {
        _bridgeReady = ready;
        _status = ready ? 'Controls ready' : 'Controls unavailable';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _bridgeReady = false;
        _status = 'Controls unavailable';
      });
    }
  }

  Future<void> _send(int button, bool pressed) async {
    if (!_bridgeReady || !mounted) return;
    try {
      final result = await _browser.runJavaScriptReturningResult(
          XboxVirtualGamepad.buttonScript(button, pressed));
      if (!mounted) return;
      if (result.toString().toLowerCase() == 'false') {
        setState(() {
          _bridgeReady = false;
          _status = 'Reconnect controls';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _bridgeReady = false;
        _status = 'Reconnect controls';
      });
    }
  }

  Future<void> _queueInput(int button, bool pressed) async {
    final previous = _inputQueue;
    final done = Completer<void>();
    _inputQueue = done.future;
    try {
      await previous;
      if (!pressed) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (mounted) await _send(button, pressed);
    } finally {
      done.complete();
    }
  }

  void _press(int button) => unawaited(_queueInput(button, true));

  void _release(int button) => unawaited(_queueInput(button, false));

  Future<void> _releaseAll() async {
    try {
      await _browser.runJavaScript(XboxVirtualGamepad.releaseScript);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_releaseAll());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_releaseAll());
    super.dispose();
  }

  Future<void> _openSafari() async {
    await launchUrl(XboxRemotePlayLauncher.uri,
        mode: LaunchMode.externalApplication);
  }

  Widget _control(String label, int button, Color background,
      {double width = 55}) {
    return Semantics(
      button: true,
      label: 'Xbox $label',
      enabled: _bridgeReady,
      child: Listener(
        onPointerDown: _bridgeReady ? (_) => _press(button) : null,
        onPointerUp: _bridgeReady ? (_) => _release(button) : null,
        onPointerCancel: _bridgeReady ? (_) => _release(button) : null,
        child: Container(
          width: width,
          height: 42,
          alignment: Alignment.center,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: _bridgeReady ? background : Colors.grey.shade300,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label, style: TextStyle(
            fontWeight: FontWeight.w700,
            color: _bridgeReady ? Colors.white : Colors.black45,
          )),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Xbox · Connect'),
        actions: [
          IconButton(
            tooltip: 'Open Remote Play in Safari',
            icon: const Icon(Icons.open_in_browser),
            onPressed: _openSafari,
          ),
          IconButton(
            tooltip: 'Retry virtual controller',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null
                : () => _prepareGamepad(_currentUrl),
          ),
        ],
      ),
      body: SafeArea(child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 7),
          child: Row(children: [
            Icon(_bridgeReady ? Icons.check_circle_rounded
                : Icons.circle_outlined, size: 15,
                color: _bridgeReady ? Colors.green : Colors.grey),
            const SizedBox(width: 6),
            Text(_status, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        if (_loading) const LinearProgressIndicator(),
        Expanded(child: WebViewWidget(controller: _browser)),
        Container(
          padding: const EdgeInsets.fromLTRB(4, 5, 4, 8),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _control('LT', XboxVirtualGamepad.lt, accent, width: 66),
              _control('LB', XboxVirtualGamepad.lb, accent, width: 66),
              _control('RB', XboxVirtualGamepad.rb, accent, width: 66),
              _control('RT', XboxVirtualGamepad.rt, accent, width: 66),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              SizedBox(width: 180, child: Column(children: [
                _control('↑', XboxVirtualGamepad.up, accent),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _control('←', XboxVirtualGamepad.left, accent, width: 48),
                  _control('→', XboxVirtualGamepad.right, accent, width: 48),
                ]),
                _control('↓', XboxVirtualGamepad.down, accent),
              ])),
              SizedBox(width: 160, child: Column(children: [
                _control('Y', XboxVirtualGamepad.buttonY,
                    Colors.amber.shade700),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _control('X', XboxVirtualGamepad.buttonX,
                      Colors.blue.shade700, width: 48),
                  _control('B', XboxVirtualGamepad.buttonB,
                      Colors.red.shade700, width: 48),
                ]),
                _control('A', XboxVirtualGamepad.buttonA,
                    Colors.green.shade700),
              ])),
            ]),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _control('View', XboxVirtualGamepad.view, accent, width: 77),
              _control('Xbox', XboxVirtualGamepad.guide, accent, width: 77),
              _control('Menu', XboxVirtualGamepad.menu, accent, width: 77),
            ]),
          ]),
        ),
      ])),
    );
  }
}
