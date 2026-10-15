import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'speaker_notes.dart';

/// PPTX is explicitly selected on the phone; no notes go to the agent.
class SpeakerNotesPanel extends StatefulWidget {
  const SpeakerNotesPanel({
    super.key, required this.slide, required this.onSlideChanged,
    required this.landscape,
  });
  final int slide;
  final ValueChanged<int> onSlideChanged;
  final bool landscape;

  @override
  State<SpeakerNotesPanel> createState() => _SpeakerNotesPanelState();
}

class _SpeakerNotesPanelState extends State<SpeakerNotesPanel> {
  SpeakerNotesDeck? _deck;
  String? _error;
  bool _loading = false;
  double _fontSize = 18;

  Future<void> _load() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final selected = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['pptx'],
        withData: true, allowMultiple: false,
      );
      if (!mounted || selected == null || selected.files.isEmpty) return;
      final file = selected.files.single;
      if (!file.name.toLowerCase().endsWith('.pptx') ||
          file.size > SpeakerNotesParser.maxFileBytes) {
        throw const FormatException('Select a .pptx file under 24 MB.');
      }
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes == null) {
        throw const FormatException('The selected PowerPoint could not be read.');
      }
      final deck = SpeakerNotesParser.parse(bytes, name: file.name);
      if (mounted) {
        setState(() { _deck = deck; _error = null; });
        widget.onSlideChanged(1);
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to read the PowerPoint file. '
          'Try saving it as .pptx again.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deck = _deck;
    final current = deck == null ? widget.slide :
        widget.slide.clamp(1, deck.slideCount).toInt();
    return Card(
      key: const ValueKey('speaker-notes-panel'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Speaker notes',
              style: Theme.of(context).textTheme.titleMedium)),
            if (deck != null)
              IconButton(
                tooltip: 'Replace PowerPoint',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.upload_file)),
            if (deck != null)
              IconButton(
                tooltip: 'Remove notes from phone',
                onPressed: () => setState(() { _deck = null; _error = null; }),
                icon: const Icon(Icons.close)),
          ]),
          if (deck == null) ...[
            const Text('Load a copy of the presentation on your phone. '
              'Only you will see its speaker notes.'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('load-speaker-notes'),
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.file_open),
              label: const Text('Choose PowerPoint (.pptx)'),
            ),
          ] else ...[
            Text(deck.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
            Row(children: [
              IconButton(
                key: const ValueKey('notes-slide-back'),
                tooltip: 'Previous notes only',
                onPressed: current <= 1 ? null :
                    () => widget.onSlideChanged(current - 1),
                icon: const Icon(Icons.remove_circle_outline)),
              Expanded(child: Text('Slide $current of ' + deck.slideCount.toString(),
                key: const ValueKey('speaker-notes-position'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium)),
              IconButton(
                key: const ValueKey('notes-slide-forward'),
                tooltip: 'Next notes only',
                onPressed: current >= deck.slideCount ? null :
                    () => widget.onSlideChanged(current + 1),
                icon: const Icon(Icons.add_circle_outline)),
              IconButton(
                tooltip: 'Smaller notes text',
                onPressed: _fontSize <= 14 ? null :
                    () => setState(() => _fontSize -= 2),
                icon: const Icon(Icons.text_decrease)),
              IconButton(
                tooltip: 'Larger notes text',
                onPressed: _fontSize >= 30 ? null :
                    () => setState(() => _fontSize += 2),
                icon: const Icon(Icons.text_increase)),
            ]),
            const Divider(),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.landscape ? 170 : 320),
              child: SingleChildScrollView(
                child: Text(
                  deck.notesFor(current).isEmpty
                    ? 'No speaker notes on this slide.'
                    : deck.notesFor(current),
                  key: const ValueKey('speaker-notes-text'),
                  style: TextStyle(fontSize: _fontSize, height: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('The notes follow TapTether Next/Previous. '
              'Use − / + above if you change slides directly on the Mac. '
              'Notes stay on this phone.',
              style: Theme.of(context).textTheme.bodySmall),
          ],
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Text(_error!, style: TextStyle(
              color: Theme.of(context).colorScheme.error)),
        ]),
      ),
    );
  }
}
