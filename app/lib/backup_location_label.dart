/// Short, human-friendly Files destination labels for the backup screen.
///
/// FilePicker can return iOS provider internals such as
/// /private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs.
/// Never display those paths or provider identifiers in the main UI.
String backupLocationLabel({String? automaticFolder, String? manualPath}) {
  final automatic = (automaticFolder ?? '').trim();
  final manual = (manualPath ?? '').trim();
  final chosen = automatic.isNotEmpty ? automatic : manual;
  if (chosen.isEmpty) return 'Choose a folder';

  final normalized = chosen.replaceAll('\\', '/');
  const cloud = 'com~apple~CloudDocs';
  final cloudIndex = normalized.indexOf(cloud);
  if (cloudIndex >= 0) {
    var suffix = normalized.substring(cloudIndex + cloud.length);
    suffix = suffix.replaceFirst(RegExp(r'^/+'), '');
    final folders = suffix.split('/')
        .where((part) => part.isNotEmpty && !part.endsWith('.ttbackup'))
        .toList();
    return folders.isEmpty
        ? 'iCloud Drive'
        : 'iCloud Drive / ${folders.join(' / ')}';
  }
  if (normalized.toLowerCase().startsWith('icloud drive')) {
    return normalized;
  }
  // The native folder channel reports "Files / <folder name>". Only
  // show its friendly folder name; never claim it is on iCloud.
  if (normalized.startsWith('Files / ')) {
    final folder = normalized.substring('Files / '.length).trim();
    if (folder.isNotEmpty && !folder.contains('/') && !folder.contains('~')) {
      return 'Files / $folder';
    }
  }
  // Raw local provider paths are unstable and must not be shown.
  return 'Files';
}
