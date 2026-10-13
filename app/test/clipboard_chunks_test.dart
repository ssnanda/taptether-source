import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/clipboard_chunks.dart';

void main() {
  test('clipboard split preserves UTF-8 text without exceeding command limit', () {
    final value = "${List.filled(255, 'A').join()}😀${List.filled(200, '世界').join()}";
    final chunks = clipboardChunks(value);
    expect(chunks.join(), value);
    expect(chunks.length, greaterThan(1));
    for (final chunk in chunks) {
      expect(utf8.encode(chunk).length, lessThanOrEqualTo(256));
    }
  });

  test('rejects oversized clipboard and allows empty clipboard', () {
    expect(clipboardChunks(''), isEmpty);
    expect(() => clipboardChunks(List.filled(4097, 'x').join()), throwsFormatException);
    expect(() => clipboardChunks('hello', chunkBytes: 1), throwsArgumentError);
  });
}
