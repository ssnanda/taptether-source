import 'dart:convert';

/// Human-readable inspection of verified backup data. No raw records,
/// fingerprint material, tokens, private keys or other secrets are surfaced.
class BackupPreview {
  BackupPreview._(this.recordCount, this.groups, this.otherRecordCount);

  final int recordCount;
  final Map<String, List<String>> groups;
  final int otherRecordCount;

  int get deviceCount => groups.values.fold<int>(0,
      (total, names) => total + names.length);

  static BackupPreview fromRecords(Map<String, String> records) {
    const kinds = <String, String>{
      'taptether.trusted.computers.v1': 'Computers',
      'taptether.lg.webos.pairings.v1': 'LG TVs',
      'taptether.samsung.tv.pairings.v1': 'Samsung TVs',
    };
    final groups = <String, List<String>>{};
    var deviceRecords = 0;
    for (final source in kinds.entries) {
      final data = records[source.key];
      if (data == null) continue;
      deviceRecords++;
      final names = <String>[];
      try {
        final parsed = jsonDecode(data);
        if (parsed is List) {
          for (final item in parsed) {
            if (item is! Map) continue;
            final raw = item['name'];
            if (raw is! String) continue;
            final cleaned = raw.replaceAll(RegExp(r'[\x00-\x1F]'), ' ')
                .trim();
            if (cleaned.isNotEmpty) {
              names.add(cleaned.length > 70
                  ? '${cleaned.substring(0, 70)}…' : cleaned);
            }
          }
        }
      } catch (_) {
        // Malformed names are simply omitted from the preview.
      }
      groups[source.value] = names;
    }
    return BackupPreview._(
      records.length, groups, records.length - deviceRecords);
  }
}
