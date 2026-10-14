/// Turns remote dpkg/apt output into a fixed diagnostic code and safe message.
/// Never surface raw command output: repository URLs or later setup stages
/// may contain secrets.
String ubuntuPackageFailureMessage(String output) {
  final details = output.toLowerCase();
  String code, description;

  if (details.contains("couldn't be accessed by user '_apt'") ||
      details.contains('pkgacquire::run (13: permission denied)')) {
    code = 'PKG-APT-SANDBOX';
    description = 'The previous apt installer could not read the package '
        'inside the private SSH staging folder. The updated installer uses '
        'dpkg directly without exposing that folder.';
  } else if (details.contains('xdotool') &&
      (details.contains('not installable') ||
          details.contains('unmet dependencies') ||
          details.contains('unable to locate package'))) {
    code = 'PKG-XDOTOOL';
    description = 'Ubuntu cannot resolve the optional xdotool dependency. '
        'TapTether makes xdotool optional; retry with the current version.';
  } else if (details.contains('could not get lock') ||
      details.contains('unable to acquire the dpkg frontend lock') ||
      details.contains('is another process using it') ||
      details.contains('held by process')) {
    code = 'PKG-LOCK';
    description = 'Another package-manager operation is running. '
        'Wait for Ubuntu updates to finish, then retry.';
  } else if (details.contains('temporary failure resolving') ||
      details.contains('failed to fetch') ||
      details.contains('unable to fetch some archives')) {
    code = 'PKG-NETWORK';
    description = 'Ubuntu could not download a required package. '
        'Check the target computer network and configured repositories.';
  } else if (details.contains('no space left on device') ||
      details.contains('not enough free space')) {
    code = 'PKG-SPACE';
    description = 'Ubuntu has insufficient disk space. '
        'Free space on the target computer and retry.';
  } else if (details.contains('not a debian format archive') ||
      details.contains('invalid archive signature') ||
      details.contains('unexpected end of file or stream')) {
    code = 'PKG-DEB';
    description = 'Ubuntu rejected the installer package format. '
        'Rebuild or download the correct agent package.';
  } else if (details.contains('unmet dependencies') ||
      details.contains('unable to correct problems') ||
      details.contains('not going to be installed')) {
    code = 'PKG-DEPENDENCIES';
    description = 'Ubuntu has unresolved package dependencies. '
        'Review package sources and pending system updates.';
  } else if (details.contains('permission denied') ||
      details.contains('could not open lock file')) {
    code = 'PKG-PERMISSION';
    description = 'Ubuntu returned a permission error during package '
        'installation. Sudo authentication may already have succeeded. '
        'Check the package folder and dpkg permissions.';
  } else {
    code = 'PKG-UNKNOWN';
    description = 'Ubuntu failed to install the agent package. '
        'Inspect apt/dpkg health and package sources on the target computer.';
  }

  return '[$code] $description (stage: package installation, exit code: 42).';
}
