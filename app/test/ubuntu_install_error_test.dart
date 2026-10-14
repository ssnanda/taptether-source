import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/ubuntu_install_error.dart';

void main() {
  test('classifies missing X11 fallback and generic dependency failures', () {
    expect(ubuntuPackageFailureMessage(
        'Depends: xdotool but it is not installable'), contains('[APT-XDOTOOL]'));
    expect(ubuntuPackageFailureMessage(
        'Unmet dependencies: broken-package'), contains('[APT-DEPENDENCIES]'));
  });

  test('classifies locks, repository failure and disk exhaustion', () {
    expect(ubuntuPackageFailureMessage(
        'Could not get lock /var/lib/dpkg/lock'), contains('[APT-LOCK]'));
    expect(ubuntuPackageFailureMessage(
        'Temporary failure resolving archive.ubuntu.com'), contains('[APT-NETWORK]'));
    expect(ubuntuPackageFailureMessage(
        'No space left on device'), contains('[APT-SPACE]'));
  });

  test('classifies corrupt archives and sudo permission failures', () {
    expect(ubuntuPackageFailureMessage(
        'not a Debian format archive'), contains('[APT-DEB]'));
    expect(ubuntuPackageFailureMessage(
        'Could not open lock file: Permission denied'), contains('[APT-PERMISSION]'));
  });

  test('does not include raw logs, repo URLs or credentials', () {
    const raw = 'Unexpected apt error\n'
        'https://myusername:password123@example.org/private/repo\n'
        'Pairing token: 00112233445566778899';
    final message = ubuntuPackageFailureMessage(raw);
    expect(message, contains('[APT-UNKNOWN]'));
    expect(message, isNot(contains('password123')));
    expect(message, isNot(contains('Pairing token:')));
    expect(message, isNot(contains('example.org')));
    expect(message, isNot(contains('00112233445566778899')));
  });
}
