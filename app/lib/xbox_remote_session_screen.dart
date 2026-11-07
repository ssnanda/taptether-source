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
  const XboxRemoteSessionScreen({
    super.key, required this.host, this.name = 'Xbox',
    this.openOfficialAtStart = true, this.onManage,
  });
  final String host;
  final String name;
  final bool openOfficialAtStart;
  final VoidCallback? onManage;

  @override
  State<XboxRemoteSessionScreen> createState() =>
      _XboxRemoteSessionScreenState();
}

class _XboxRemoteSessionScreenState extends State<XboxRemoteSessionScreen>
    with WidgetsBindingObserver {
  late final WebViewController _browser;
  bool _loading = true;
  bool _bridgeReady = false;
  bool _showExperimentalWeb = false;
  String _status = 'Open Microsoft Remote Play';
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
            _status = XboxRemoteWebStatus.label(url);
            _currentUrl = url;
          });
        },
        onPageFinished: (url) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _currentUrl = url;
            _status = XboxRemoteWebStatus.label(url);
            _bridgeReady = false;
          });
          if (XboxRemoteWebStatus.phase(url) ==
              XboxRemoteWebPhase.remotePlay) {
            unawaited(_prepareGamepad(url));
          }
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.openOfficialAtStart) {
        unawaited(_openSupportedBrowser());
      }
    });
  }

  Future<void> _prepareGamepad(String url) async {
    if (!XboxVirtualGamepad.isMicrosoftXboxPage(url) ||
        XboxRemoteWebStatus.phase(url) != XboxRemoteWebPhase.remotePlay) {
      if (mounted) {
        setState(() {
          _bridgeReady = false;
          _status = XboxRemoteWebStatus.label(url);
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
        _status = ready
            ? 'Experimental buttons injected · console not verified'
            : 'Web controls unavailable · use Microsoft Remote Play';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _bridgeReady = false;
        _status = 'Web controls unavailable · use Microsoft Remote Play';
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

  Future<void> _openSupportedBrowser() async {
    final success = await const XboxRemotePlayLauncher().connect();
    if (!mounted) {
      return;
    }
    if (!success) {
      setState(() => _status = 'Could not open Microsoft Remote Play');
    }
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
        title: Text(widget.name.isEmpty
            ? 'Xbox · Remote Play' : '${widget.name} · Remote Play'),
        actions: [
          if (widget.onManage != null)
            IconButton(
              key: const ValueKey('xbox-session-manage'),
              tooltip: 'Xbox connection settings',
              icon: const Icon(Icons.tune_rounded),
              onPressed: widget.onManage,
            ),
          IconButton(
            tooltip: 'Open Remote Play in Safari',
            icon: const Icon(Icons.open_in_browser),
            onPressed: _openSafari,
          ),
          if (_showExperimentalWeb) IconButton(
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Saved Xbox · ${widget.host}',
                style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 5),
              Text(_status, key: const ValueKey('xbox-web-status'),
                style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 7),
              FilledButton.icon(
                key: const ValueKey('xbox-open-official-remote-play'),
                onPressed: _openSupportedBrowser,
                icon: const Icon(Icons.open_in_browser),
                label: const Text('Open Microsoft Remote Play'),
              ),
              const SizedBox(height: 4),
              Text('Microsoft handles sign-in and console selection. '
                  'A saved IP is not an authenticated controller connection. '
                  'If the Xbox homepage appears, select Remote Play.',
                style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        if (_loading && _showExperimentalWeb)
          const LinearProgressIndicator(),
        Expanded(child: _showExperimentalWeb
            ? WebViewWidget(controller: _browser)
            : Center(child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.sports_esports_rounded, size: 64,
                      color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 12),
                    Text('Xbox address saved',
                      style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text('Remote Play opens through Microsoft. '
                        'Your saved Xbox remains on the TapTether dashboard. '
                        'Microsoft sign-in and console selection happen '
                        'in the browser.', textAlign: TextAlign.center),
                    const SizedBox(height: 18),
                    OutlinedButton.icon(
                      key: const ValueKey('xbox-show-experimental-web'),
                      onPressed: () => setState(
                          () => _showExperimentalWeb = true),
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('Try experimental web controls'),
                    ),
                  ],
                ),
              )),
        ),
        if (_bridgeReady && _showExperimentalWeb) Container(
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
