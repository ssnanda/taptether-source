import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:taptether/xbox_remote_play.dart';

void main() {
  test('connect opens verified Microsoft Remote Play URL inside app',
      () async {
    final calls = <LaunchMode>[];
    final launcher = XboxRemotePlayLauncher(open: (url, mode) async {
      expect(url.scheme, 'https');
      expect(url.host, 'www.xbox.com');
      expect(url.path, '/remoteplay');
      calls.add(mode);
      return true;
    });
    expect(await launcher.connect(), true);
    expect(calls, [LaunchMode.inAppBrowserView]);
  });

  test('connect falls back to external Safari when in-app fails',
      () async {
    final calls = <LaunchMode>[];
    final launcher = XboxRemotePlayLauncher(open: (url, mode) async {
      calls.add(mode);
      if (mode == LaunchMode.inAppBrowserView) {
        throw Exception('Not supported');
      }
      return true;
    });
    expect(await launcher.connect(), true);
    expect(calls, [
      LaunchMode.inAppBrowserView,
      LaunchMode.externalApplication,
    ]);
  });

  test('connect never falsely reports success when browsers fail',
      () async {
    final launcher = XboxRemotePlayLauncher(
        open: (url, mode) async => false);
    expect(await launcher.connect(), false);
  });
}
