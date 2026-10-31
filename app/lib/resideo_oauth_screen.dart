import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'resideo_api.dart';

/// Resideo website sign-in. The registered loopback callback is intercepted
/// before the web view tries to connect to localhost; no local server needed.
/// Only the short-lived authorization code leaves this view to be exchanged.
class ResideoOAuthScreen extends StatefulWidget {
  const ResideoOAuthScreen({
    super.key,
    required this.authorizationUrl,
    required this.callbackUrl,
    required this.state,
  });

  final Uri authorizationUrl;
  final String callbackUrl;
  final String state;

  @override
  State<ResideoOAuthScreen> createState() => _ResideoOAuthScreenState();
}

class _ResideoOAuthScreenState extends State<ResideoOAuthScreen> {
  late final WebViewController _web;
  String? _error;
  int _progress = 0;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (progress) {
          if (mounted) {
            setState(() => _progress = progress);
          }
        },
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          final redirect = ResideoConnection.validateRedirect(widget.callbackUrl);
          final matches = uri != null &&
              uri.scheme == redirect.scheme &&
              uri.host == redirect.host &&
              uri.port == redirect.port &&
              uri.path == redirect.path;
          if (!matches) {
            return NavigationDecision.navigate;
          }
          if (_completed) {
            return NavigationDecision.prevent;
          }
          try {
            final code = ResideoConnection.authorizationCode(
              request.url, redirect: widget.callbackUrl, state: widget.state);
            _completed = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                Navigator.of(context).pop(code);
              }
            });
          } on FormatException catch (error) {
            if (mounted) {
              setState(() => _error = error.message);
            }
          }
          return NavigationDecision.prevent;
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame != true || !mounted) {
            return;
          }
          setState(() => _error =
              'Resideo sign-in could not load. Try the Safari option below.');
        },
      ))
      ..loadRequest(widget.authorizationUrl);
  }

  Future<void> _openSafari() async {
    final opened = await launchUrl(
      widget.authorizationUrl, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      setState(() => _error = 'Could not open Resideo in Safari.');
    }
    // Settings retains a paste-the-redirect fallback for external browsers.
    if (opened && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sign in to Resideo')),
    body: Column(children: [
      if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
      if (_error != null)
        Padding(padding: const EdgeInsets.all(12),
          child: Text(_error!, style: TextStyle(
              color: Theme.of(context).colorScheme.error))),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text('Sign in to your Honeywell Home account and approve TapTether. '
            'The authorization code is captured automatically.'),
      ),
      Expanded(child: WebViewWidget(controller: _web)),
      SafeArea(top: false, child: TextButton.icon(
        icon: const Icon(Icons.open_in_browser),
        label: const Text('Sign in using Safari instead'),
        onPressed: _openSafari,
      )),
    ]),
  );
}
