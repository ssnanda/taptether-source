import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/sideloader_api.dart';
import 'package:taptether/sideloader_screen.dart';

void main() {
  test('SideLoader URL accepts LAN and private VPN endpoints', () {
    expect(SideLoaderApi.validateServer('http://100.106.150.135:38080')
        .host, '100.106.150.135');
    expect(SideLoaderApi.validateServer('https://sideloader.example.com')
        .scheme, 'https');
    for (final invalid in [
      'ftp://example.com', 'http://u:password@example.com',
      'https://example.com/path', 'https://example.com/?token=secret',
    ]) {
      expect(() => SideLoaderApi.validateServer(invalid), throwsFormatException);
    }
  });

  test('inventory matches device-specific signed bundle IDs', () {
    final row = SideLoaderPhoneApp('com.example.app.ABC1234567', '2.3');
    expect(row.matches('com.example.app'), isTrue);
    expect(row.matches('com.example.other'), isFalse);
    expect(SideLoaderPhoneApp('com.example.app.suffix', '2.3')
        .matches('com.example.app'), isFalse);
  });

  test('snapshot does not infer reachable devices or signing status', () {
    final snapshot = SideLoaderState.fromJson({
      'now': 1770000000,
      'registered': [
        {'udid': 'UDID', 'name': 'iPhone', 'live': {'reachable': false}}
      ],
      'signing_guard': {'blocked': true, 'message': 'Apple verification failed'},
      'apps': [{
        'id': 'com.example.app',
        'bundle_id': 'com.example.app',
        'name': 'Example',
        'version': '1.3',
        'targets': [{
          'udid': 'UDID',
          'signature': {'expiry': 1770000000 + 7200},
          'installation': {'state': 'installed'},
        }]
      }],
    });
    expect(snapshot.blocked, isTrue);
    expect(snapshot.devices.single.reachable, isFalse);
    expect(snapshot.apps.single.targetFor('udid')?.remaining(snapshot.now),
        '2 h 0 m left');
    expect(snapshot.apps.single.targetFor('missing'), isNull);
  });

  test('latest source comparison supports dotted versions and same-version reinstall', () {
    expect(sideLoaderNewerVersion('1.10', '1.9'), isTrue);
    expect(sideLoaderNewerVersion('1.2.0', '1.2'), isFalse);
    expect(sideLoaderNewerVersion('1.2', '2.0'), isFalse);
    final candidates = [
      const SideLoaderSourceApp('old', 'repo', 'com.example.app', '1.0', '1'),
      const SideLoaderSourceApp('new', 'repo', 'com.example.app', '1.5', '3'),
      const SideLoaderSourceApp('other', 'repo', 'com.unrelated.app', '9', '1'),
    ];
    expect(sideLoaderLatestSource(candidates, 'com.example.app')?.sourceId,
        'new');
    expect(sideLoaderLatestSource(candidates, 'com.unlisted.app'), isNull);
    // Same version is still eligible as a Reinstall latest source.
    expect(sideLoaderLatestSource([
      const SideLoaderSourceApp('same', 'repo', 'com.example.app', '1.0', '1')
    ], 'com.example.app')?.sourceId, 'same');
  });

  test('Apple challenge is represented separately from signed job completion', () {
    final job = SideLoaderJob.fromJson({
      'id': 'abc', 'title': 'Sign App', 'running': true,
      'stage': 'signin', 'needs_input': true, 'accepts_input': true,
      'verification_delivery': 'reported_sent',
      'verification_seconds_remaining': 43,
    });
    expect(job.needsInput, isTrue);
    expect(job.acceptsInput, isTrue);
    expect(job.delivery, 'reported_sent');
    expect(job.rc, isNull);
  });
}
