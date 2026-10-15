import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Speaker notes are parsed on the phone from a user-selected .pptx.
/// They are never transmitted to the computer, an external service, or disk.
class SpeakerNotesDeck {
  const SpeakerNotesDeck({
    required this.name,
    required this.slideCount,
    required this.notes,
  });

  final String name;
  final int slideCount;
  final Map<int, String> notes;

  String notesFor(int slide) => notes[slide] ?? '';
}

class SpeakerNotesParser {
  static const maxFileBytes = 24 * 1024 * 1024;
  static const maxXmlBytes = 2 * 1024 * 1024;

  static SpeakerNotesDeck parse(Uint8List input, {required String name}) {
    if (input.isEmpty || input.length > maxFileBytes) {
      throw const FormatException('Choose a PowerPoint file smaller than 24 MB.');
    }
    final archive = ZipDecoder().decodeBytes(input, verify: true);
    if (archive.files.length > 6000) {
      throw const FormatException('The PowerPoint contains too many entries.');
    }
    final files = <String, ArchiveFile>{};
    for (final entry in archive.files) {
      if (entry.isFile && entry.name.startsWith('ppt/') &&
          (entry.name.endsWith('.xml') || entry.name.endsWith('.rels'))) {
        files[entry.name] = entry;
      }
    }

    XmlDocument load(String path) {
      final entry = files[path];
      if (entry == null || entry.size > maxXmlBytes) {
        throw const FormatException('PowerPoint slide structure is missing or too large.');
      }
      return XmlDocument.parse(utf8.decode(entry.content as List<int>));
    }

    final document = load('ppt/presentation.xml');
    final relations = _relationships(load('ppt/_rels/presentation.xml.rels'));
    final slides = <String>[];
    for (final node in document.descendants.whereType<XmlElement>()) {
      if (node.name.local != 'sldId') continue;
      final id = _attr(node, 'id');
      final target = relations[id];
      if (target != null) {
        slides.add(_resolve('ppt/', target));
      }
    }
    if (slides.isEmpty || slides.length > 1000) {
      throw const FormatException('No usable PowerPoint slides found.');
    }
    final slideNumbers = <String, int>{};
    for (var i = 0; i < slides.length; i++) {
      slideNumbers[slides[i]] = i + 1;
    }

    final notes = <int, String>{};
    for (final path in files.keys) {
      if (!RegExp(r'^ppt/notesSlides/notesSlide[0-9]+\.xml$').hasMatch(path)) {
        continue;
      }
      final basename = path.substring('ppt/notesSlides/'.length);
      final relPath = 'ppt/notesSlides/_rels/$basename.rels';
      if (!files.containsKey(relPath)) continue;
      final map = _relationships(load(relPath), type: 'slide');
      if (map.isEmpty) continue;
      final slidePath = _resolve('ppt/notesSlides/', map.values.first);
      final number = slideNumbers[slidePath];
      if (number == null) continue;
      final slideNotes = load(path);
      final paragraphs = <String>[];
      for (final shape in slideNotes.descendants.whereType<XmlElement>()) {
        if (shape.name.local != 'sp') continue;
        final isBody = shape.descendants.whereType<XmlElement>().any(
          (element) => element.name.local == 'ph' &&
              element.getAttribute('type') == 'body',
        );
        if (!isBody) continue;
        for (final para in shape.descendants.whereType<XmlElement>()) {
          if (para.name.local != 'p') continue;
          final text = para.descendants.whereType<XmlElement>()
              .where((e) => e.name.local == 't')
              .map((e) => e.innerText).join().trim();
          if (text.isNotEmpty) paragraphs.add(text);
        }
      }
      if (paragraphs.isNotEmpty) notes[number] = paragraphs.join('\n\n');
    }
    return SpeakerNotesDeck(name: name, slideCount: slides.length, notes: notes);
  }

  static String? _attr(XmlElement element, String local) {
    // p:sldId has BOTH id="256" (numeric slide ID) and r:id="rId4".
    // Only the relationship ID maps to ppt/_rels/presentation.xml.rels.
    for (final attribute in element.attributes) {
      if (attribute.name.local == local &&
          attribute.name.prefix == 'r') {
        return attribute.value;
      }
    }
    for (final attribute in element.attributes.reversed) {
      if (attribute.name.local == local) {
        return attribute.value;
      }
    }
    return null;
  }

  static Map<String, String> _relationships(XmlDocument xml, {String? type}) {
    final result = <String, String>{};
    for (final node in xml.descendants.whereType<XmlElement>()) {
      if (node.name.local != 'Relationship') continue;
      if (node.getAttribute('TargetMode') == 'External') continue;
      final kind = node.getAttribute('Type') ?? '';
      if (type != null && !kind.endsWith('/$type')) continue;
      final id = node.getAttribute('Id');
      final target = node.getAttribute('Target');
      if (id != null && target != null) result[id] = target;
    }
    return result;
  }

  /// OOXML relations may use ../, /ppt/... or ppt/... paths.
  static String _resolve(String parent, String target) {
    if (target.startsWith('/')) target = target.substring(1);
    if (target.startsWith('ppt/')) return target;
    final parts = <String>[];
    for (final part in (parent + target).split('/')) {
      if (part == '.' || part.isEmpty) continue;
      if (part == '..') {
        if (parts.isEmpty) throw const FormatException('Invalid PowerPoint relation.');
        parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }
}
