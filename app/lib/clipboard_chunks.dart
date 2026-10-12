import 'dart:convert';

/// Splits explicitly shared clipboard text into valid UTF-8 command payloads.
/// Never splits a Unicode scalar across requests; the agent limits each text
/// event to 256 bytes and the UI limits a transfer to 4 KiB.
List<String> clipboardChunks(String value, {int maxBytes = 4096, int chunkBytes = 256}) {
  if (chunkBytes < 4 || maxBytes < chunkBytes) {
    throw ArgumentError('Invalid clipboard transfer limits.');
  }
  if (value.isEmpty) return const [];
  if (utf8.encode(value).length > maxBytes) {
    throw const FormatException('Clipboard exceeds the 4 KB safety limit.');
  }

  final output = <String>[];
  var chunk = StringBuffer();
  var length = 0;
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    final size = utf8.encode(character).length;
    if (length + size > chunkBytes) {
      output.add(chunk.toString());
      chunk = StringBuffer();
      length = 0;
    }
    chunk.write(character);
    length += size;
  }
  if (length > 0) output.add(chunk.toString());
  return output;
}
