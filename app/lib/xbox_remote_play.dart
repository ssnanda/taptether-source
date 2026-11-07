import 'package:url_launcher/url_launcher.dart';

/// Official Microsoft Remote Play URL. The Microsoft browser session
/// authenticates the user and selects the Xbox; TapTether never stores
/// account passwords, OAuth tokens, or manufactures an authenticated state.
typedef XboxLaunch = Future<bool> Function(Uri url, LaunchMode mode);

Future<bool> _openMicrosoftXbox(Uri url, LaunchMode mode) =>
    launchUrl(url, mode: mode);

class XboxRemotePlayLauncher {
  static final Uri uri = Uri.https('www.xbox.com', '/remoteplay');

  const XboxRemotePlayLauncher({
    this.open = _openMicrosoftXbox,
  });

  final XboxLaunch open;

  /// In-app Safari view uses Microsoft's own controls; fall back to Safari
  /// if iOS refuses to present a supported browser view.
  Future<bool> connect() async {
    try {
      if (await open(uri, LaunchMode.inAppBrowserView)) return true;
    } catch (_) {
      // System browser might not support an in-app presentation.
    }
    try {
      return await open(uri, LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}

enum XboxRemoteWebPhase { signIn, xboxHome, remotePlay, other }

/// Domain and URL classification only: a web page URL cannot prove that a
/// Microsoft account is signed in or that a console is remotely connected.
class XboxRemoteWebStatus {
  static XboxRemoteWebPhase phase(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      return XboxRemoteWebPhase.other;
    }
    final host = uri.host.toLowerCase();
    if (host == 'login.live.com' ||
        host == 'login.microsoftonline.com' ||
        host == 'account.microsoft.com' ||
        host == 'login.microsoft.com') {
      return XboxRemoteWebPhase.signIn;
    }
    if (host != 'xbox.com' && host != 'www.xbox.com') {
      return XboxRemoteWebPhase.other;
    }
    final path = uri.path.toLowerCase().replaceAll('-', '');
    final query = uri.query.toLowerCase().replaceAll('-', '');
    if (path.contains('remoteplay') || query.contains('remoteplay')) {
      return XboxRemoteWebPhase.remotePlay;
    }
    return XboxRemoteWebPhase.xboxHome;
  }

  static String label(String url) {
    switch (phase(url)) {
      case XboxRemoteWebPhase.signIn:
        return 'Microsoft sign-in in progress';
      case XboxRemoteWebPhase.xboxHome:
        return 'Xbox website · choose Remote Play';
      case XboxRemoteWebPhase.remotePlay:
        return 'Remote Play web page · console not yet verified';
      case XboxRemoteWebPhase.other:
        return 'Microsoft website · console not yet connected';
    }
  }
}
