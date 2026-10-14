/// Turns remote dpkg/apt output into a fixed diagnostic code and safe message.
/// Never surface raw command output: repository URLs or later setup stages
/// may contain secrets.
String ubuntuPackageFailureMessage(String output) {
  // Prefer the isolated dpkg-only output. Legacy reports can still be
  // classified, but no unfiltered terminal output is ever exported.
  final segment = RegExp(
    r'TAPTETHER_DPKG_BEGIN\s*([\s\S]*?)\s*TAPTETHER_DPKG_END',
  ).firstMatch(output);
  final isolated = segment?.group(1) ?? output;
  final details = isolated.toLowerCase();
  String code, description;

  if (details.contains('trying to overwrite') ||
      details.contains('which is also in package') ||
      details.contains('conflicting packages')) {
    code = 'PKG-CONFLICT';
    description = 'An existing Ubuntu package owns a file needed by the '
        'agent. See the sanitized dpkg detail for more information.';
  } else if (details.contains('package architecture') &&
      details.contains('does not match system')) {
    code = 'PKG-ARCH';
    description = 'The agent package does not match the Ubuntu CPU architecture.';
  } else if (details.contains('dpkg was interrupted') ||
      details.contains('status database area is locked')) {
    code = 'PKG-DATABASE';
    description = 'Ubuntu package database needs repair or is being updated.';
  } else if (details.contains('cannot access archive') ||
      details.contains('failed to open archive') ||
      details.contains('no such file or directory')) {
    code = 'PKG-ARCHIVE-ACCESS';
    description = 'Ubuntu could not open the uploaded package.';
  } else if (details.contains('post-installation script') ||
      details.contains('pre-installation script')) {
    code = 'PKG-SCRIPT';
    description = 'A Debian package installation script failed.';
  } else if (details.contains('unable to create') ||
      details.contains('unable to open') ||
      details.contains('failed to write') ||
      details.contains('unable to stat')) {
    code = 'PKG-FILESYSTEM';
    description = 'Ubuntu could not write or inspect files during installation.';
  } else if (details.contains("couldn't be accessed by user '_apt'") ||
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

  final hint = _safeDpkgHint(segment?.group(1) ?? '');
  final status = RegExp(r'TAPTETHER_DPKG_STATUS:([0-9]{1,3})')
      .firstMatch(output)?.group(1);
  return '[$code] $description (stage: package installation, '
      'exit code: 42${status == null ? '' : ', dpkg exit: $status'}).'
      '${hint == null ? '' : ' Sanitized dpkg detail: $hint'}';
}

/// Only include a bounded line from dpkg itself, never stdout from SSH or
/// sudo authentication. Scrub file paths, URLs, emails, IPs and opaque tokens.
String? _safeDpkgHint(String isolated) {
  for (final line in isolated.split(RegExp(r'\r?\n'))) {
    if (!RegExp(r'^\s*dpkg(?:-deb)?:\s*(?:error|dependency problems)',
            caseSensitive: false)
        .hasMatch(line)) {
      continue;
    }
    var safe = line.trim()
        .replaceAll(RegExp(r'https?://\S+', caseSensitive: false), '[url]')
        .replaceAll(RegExp(r'/\S+'), '[path]')
        .replaceAll(RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
            '[email]')
        .replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'), '[ip]')
        .replaceAll(RegExp(r'[A-Za-z0-9+/_=-]{24,}'), '[redacted]')
        .replaceAll(RegExp(r'[^\x20-\x7E]'), ' ');
    if (safe.length > 200) safe = '${safe.substring(0, 200)}…';
    return safe;
  }
  return null;
}
