import 'package:url_launcher/url_launcher.dart';

/// Official Microsoft Remote Play URL. The Microsoft browser session
/// authenticates the user and selects the Xbox; TapTether never stores
/// account passwords, OAuth tokens, or manufactures an authenticated state.
class XboxRemotePlayLauncher {
  static final Uri uri = Uri.https('www.xbox.com', '/remoteplay');

  const XboxRemotePlayLauncher({
    this.open = launchUrl,
  });

  final Future<bool> Function(Uri url, {LaunchMode mode}) open;

  /// In-app Safari view uses Microsoft's own controls; fall back to Safari
  /// if iOS refuses to present a supported browser view.
  Future<bool> connect() async {
    try {
      if (await open(uri, mode: LaunchMode.inAppBrowserView)) return true;
    } catch (_) {
      // System browser might not support an in-app presentation.
    }
    try {
      return await open(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
