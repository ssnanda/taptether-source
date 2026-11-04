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
