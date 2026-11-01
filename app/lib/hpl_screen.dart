import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'hpl_inspector.dart';

/// Temporary local-only file diagnostic. iOS will not expose another app's
/// private documents, even if that app has downloaded a title for offline use.
class HplScreen extends StatefulWidget {
  const HplScreen({super.key});

  @override
  State<HplScreen> createState() => _HplScreenState();
}

class _HplScreenState extends State<HplScreen> {
  bool _reading = false;
  String? _error;
  String? _filename;
  String? _pickerCopy;
  int? _size;
  HplInspection? _inspection;

  Future<void> _inspectFile() async {
    if (_reading) return;
    setState(() {
      _reading = true;
      _error = null;
      _inspection = null;
      _filename = null;
      _pickerCopy = null;
      _size = null;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
        allowMultiple: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final item = picked.files.single;
      final localPath = item.path;
      if (localPath == null) {
        throw const FileSystemException(
            'The selected provider did not make a local file available.');
      }
      // The picker may provide a temporary cache copy. Never mistake that
      // location for the private storage location of the original app.
      final file = File(localPath);
      final reader = await file.open();
      late final Uint8List header;
      try {
        header = await reader.read(64);
      } finally {
        await reader.close();
      }
      if (!mounted) return;
      setState(() {
        _filename = item.name;
        _size = item.size;
        _pickerCopy = localPath;
        _inspection = inspectHplBytes(item.name, header);
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not read that file through Files. '
            'Choose an available local file and try again.');
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  String _displaySize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('HPL · Temporary')),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        Text('Hoopla download inspection',
            style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Hoopla offline downloads remain inside Hoopla. '
            'iOS does not permit TapTether to search Hoopla\'s private '
            'app storage or reveal its download directory.'),
        const SizedBox(height: 12),
        const Text('Choose a file that appears in the iPhone Files app. '
            'HPL checks its first 64 bytes, format and MP4 compatibility '
            'without uploading, decrypting or converting it.'),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('hpl-choose-file'),
          onPressed: _reading ? null : _inspectFile,
          icon: const Icon(Icons.folder_open_outlined),
          label: Text(_reading ? 'Inspecting…' : 'Choose file from Files'),
        ),
        if (_reading) const Padding(
          padding: EdgeInsets.only(top: 12),
          child: LinearProgressIndicator(),
        ),
        if (_error != null) Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_error!,
              style: TextStyle(color: theme.colorScheme.error)),
        ),
        if (_inspection != null) ...[
          const SizedBox(height: 14),
          Card(child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_filename ?? '', style: theme.textTheme.titleMedium),
                const SizedBox(height: 5),
                Text('Size: ${_displaySize(_size ?? 0)}'),
                Text('Detected: ${_inspection!.format}'),
                const SizedBox(height: 12),
                Text('MP4 feasibility',
                    style: theme.textTheme.titleSmall),
                Text(_inspection!.readiness),
                const SizedBox(height: 10),
                Text(_inspection!.detail),
                const Divider(height: 22),
                const Text('The path below is TapTether\'s picker-accessible '
                    'copy, NOT Hoopla\'s original download location.'),
                const SizedBox(height: 5),
                SelectableText(_pickerCopy ?? '',
                    style: theme.textTheme.bodySmall),
              ],
            ),
          )),
        ],
        const SizedBox(height: 18),
        const Text('This diagnostic does not copy books out of Hoopla, '
            'bypass library lending restrictions, or convert protected '
            'media. Accessible, unprotected audio can be assessed for '
            'a later MP4 or M4B export.'),
      ]),
    );
  }
}
