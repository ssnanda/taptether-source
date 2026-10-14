import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/ubuntu_install_error.dart';

void main() {
  test('classifies missing X11 fallback and generic dependency failures', () {
    expect(ubuntuPackageFailureMessage(
        'Depends: xdotool but it is not installable'), contains('[PKG-XDOTOOL]'));
    expect(ubuntuPackageFailureMessage(
        'Unmet dependencies: broken-package'), contains('[PKG-DEPENDENCIES]'));
  });

  test('classifies locks, repository failure and disk exhaustion', () {
    expect(ubuntuPackageFailureMessage(
        'Could not get lock /var/lib/dpkg/lock'), contains('[PKG-LOCK]'));
    expect(ubuntuPackageFailureMessage(
        'Temporary failure resolving archive.ubuntu.com'), contains('[PKG-NETWORK]'));
    expect(ubuntuPackageFailureMessage(
        'No space left on device'), contains('[PKG-SPACE]'));
  });

  test('classifies corrupt archives and package permission failures', () {
    expect(ubuntuPackageFailureMessage(
        'not a Debian format archive'), contains('[PKG-DEB]'));
    expect(ubuntuPackageFailureMessage(
        'Could not open lock file: Permission denied'), contains('[PKG-PERMISSION]'));
  });

  test('recognizes legacy _apt sandbox warnings without blaming sudo', () {
    final message = ubuntuPackageFailureMessage(
      "N: Download is performed unsandboxed as root as file "
      "'/tmp/taptether-phone.12345678/pkg.deb' couldn't be accessed "
      "by user '_apt'. - pkgAcquire::Run (13: Permission denied)",
    );
    expect(message, contains('[PKG-APT-SANDBOX]'));
    expect(message, contains('private SSH staging folder'));
    expect(message, isNot(contains('/tmp/taptether-phone.')));
  });

  test('isolated dpkg output identifies package conflicts safely', () {
    final result = ubuntuPackageFailureMessage(
      'sudo password: something-not-for-export\n'
      'TAPTETHER_DPKG_BEGIN\r\n'
      'dpkg: error processing archive /tmp/taptether-phone.1234/agent.deb (--install):\n'
      ' trying to overwrite /usr/local/bin/taptether-agent which is also in package\n'
      'TAPTETHER_DPKG_END\n'
      'TAPTETHER_DPKG_STATUS:1\n',
    );
    expect(result, contains('[PKG-CONFLICT]'));
    expect(result, contains('dpkg exit: 1'));
    expect(result, contains('Sanitized dpkg detail:'));
    expect(result, isNot(contains('/tmp/taptether-phone.')));
    expect(result, isNot(contains('something-not-for-export')));
  });

  test('unknown package error shows sanitized dpkg line only', () {
    final result = ubuntuPackageFailureMessage(
      'sudo pass-sample-abc\n'
      'TAPTETHER_DPKG_BEGIN\n'
      'dpkg: error: unexpected problem with /home/test-user/secret.txt\n'
      'TAPTETHER_DPKG_END\n',
    );
    expect(result, contains('[PKG-UNKNOWN]'));
    expect(result, contains('[path]'));
    expect(result, isNot(contains('/home/test-user/')));
    expect(result, isNot(contains('pass-sample-abc')));
  });

  test('does not include raw logs, repo URLs or credentials', () {
    const raw = 'Unexpected apt error\n'
        'https://myusername:password123@example.org/private/repo\n'
        'Pairing token: 00112233445566778899';
    final message = ubuntuPackageFailureMessage(raw);
    expect(message, contains('[PKG-UNKNOWN]'));
    expect(message, isNot(contains('password123')));
    expect(message, isNot(contains('Pairing token:')));
    expect(message, isNot(contains('example.org')));
    expect(message, isNot(contains('00112233445566778899')));
  });
}
