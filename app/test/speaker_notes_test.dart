import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/speaker_notes.dart';

Uint8List makePresentation() {
  final data = <String, String>{
    'ppt/presentation.xml':
      '<p:presentation xmlns:p="urn:p" xmlns:r="urn:r">'
      '<p:sldIdLst><p:sldId id="256" r:id="rId4"/>'
      '<p:sldId id="257" r:id="rId2"/></p:sldIdLst></p:presentation>',
    'ppt/_rels/presentation.xml.rels':
      '<Relationships><Relationship Id="rId4" Type="x/slide" '
      'Target="slides/slide5.xml"/>'
      '<Relationship Id="rId2" Type="x/slide" '
      'Target="slides/slide1.xml"/></Relationships>',
    'ppt/notesSlides/_rels/notesSlide7.xml.rels':
      '<Relationships><Relationship Id="rId3" Type="x/slide" '
      'Target="../slides/slide1.xml"/></Relationships>',
    'ppt/notesSlides/notesSlide7.xml':
      '<p:notes xmlns:p="urn:p" xmlns:a="urn:a"><p:sp>'
      '<p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr>'
      '<p:txBody><a:p><a:r><a:t>Second slide</a:t></a:r></a:p>'
      '<a:p><a:r><a:t>Summary &amp; action</a:t></a:r></a:p>'
      '</p:txBody></p:sp><p:sp><p:nvSpPr><p:nvPr>'
      '<p:ph type="sldNum"/></p:nvPr></p:nvSpPr>'
      '<p:txBody><a:p><a:r><a:t>2</a:t></a:r></a:p></p:txBody>'
      '</p:sp></p:notes>',
    'ppt/notesSlides/_rels/notesSlide99.xml.rels':
      '<Relationships><Relationship Id="rId5" Type="x/slide" '
      'Target="../slides/slide5.xml"/></Relationships>',
    'ppt/notesSlides/notesSlide99.xml':
      '<p:notes xmlns:p="urn:p" xmlns:a="urn:a"><p:sp>'
      '<p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr>'
      '<p:txBody><a:p><a:r><a:t>Opening remarks</a:t></a:r>'
      '</a:p></p:txBody></p:sp></p:notes>',
  };
  final archive = Archive();
  for (final entry in data.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test('speaker notes follow presentation order, not file numbering', () {
    final deck = SpeakerNotesParser.parse(
      makePresentation(), name: 'Demo.pptx');
    expect(deck.name, 'Demo.pptx');
    expect(deck.slideCount, 2);
    expect(deck.notesFor(1), 'Opening remarks');
    expect(deck.notesFor(2), 'Second slide\n\nSummary & action');
    expect(deck.notesFor(3), isEmpty);
    expect(deck.notesFor(2), isNot(contains('2\n')));
  });

  test('rejects empty files before attempting to decompress', () {
    expect(() => SpeakerNotesParser.parse(Uint8List(0), name: 'x.pptx'),
      throwsFormatException);
  });
}
