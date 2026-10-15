import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Ephemeral, on-device discovery diagnostics. Never log tokens, private
/// keys, certificate pins, authenticated payloads, or response bodies.
class ScanReport {
  final List<String> _lines = [];
  final int maxLines;
  ScanReport({this.maxLines = 2200});

  void clear() => _lines.clear();

  void add(String message) {
    if (_lines.length >= maxLines) {
      _lines.removeAt(0);
    }
    _lines.add('${DateTime.now().toIso8601String()}  $message');
  }

  bool get isEmpty => _lines.isEmpty;
  String get output => _lines.join('\n');
  int get length => _lines.length;
}

/// Collapsed by default. Logs remain local until the owner explicitly copies
/// them; there is no upload, analytics, or background logging.
class ScanReportPanel extends StatelessWidget {
  const ScanReportPanel({
    super.key,
    required this.title,
    required this.report,
  });

  final String title;
  final ScanReport report;

  @override
  Widget build(BuildContext context) {
    if (report.isEmpty) return const SizedBox.shrink();
    return ExpansionTile(
      key: const ValueKey('scan-full-output'),
      tilePadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text('${report.length} log entries · Stored on this device only'),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('copy-scan-output'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report.output));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Scan output copied')),
                );
              }
            },
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copy full output'),
          ),
        ),
        Container(
          alignment: Alignment.centerLeft,
          constraints: const BoxConstraints(maxHeight: 300),
          width: double.infinity,
          child: SingleChildScrollView(
            child: SelectableText(
              report.output,
              key: const ValueKey('scan-output-text'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
