import 'dart:typed_data';

/// Classifies only metadata and the first bytes of a user-selected file.
/// It neither decrypts media nor accesses another application's sandbox.
class HplInspection {
  const HplInspection({
    required this.format,
    required this.readiness,
    required this.detail,
    required this.isMedia,
  });

  final String format;
  final String readiness;
  final String detail;
  final bool isMedia;
}

bool _signature(Uint8List data, int offset, List<int> pattern) {
  if (data.length < offset + pattern.length) return false;
  for (var index = 0; index < pattern.length; index++) {
    if (data[offset + index] != pattern[index]) return false;
  }
  return true;
}

HplInspection inspectHplBytes(String filename, Uint8List bytes) {
  final lower = filename.toLowerCase();
  // Signature-based checks take precedence over a misleading extension.
  if (_signature(bytes, 4, [0x66, 0x74, 0x79, 0x70])) {
    final audio = lower.endsWith('.m4a') || lower.endsWith('.m4b') ||
        lower.endsWith('.m4p');
    return HplInspection(
      format: audio ? 'MPEG-4 audio container' : 'MPEG-4 media container',
      readiness: audio
          ? 'Already uses an MPEG-4 container. Creating an MP4 file would '
            'require checking its streams and whether they are protected.'
          : 'Already appears to be an MP4-family container.',
      detail: 'The container header is recognizable, but this does not '
          'prove that its media streams are unencrypted or playable.',
      isMedia: true,
    );
  }
  if (_signature(bytes, 0, [0x49, 0x44, 0x33]) ||
      (bytes.length >= 2 && bytes[0] == 0xff &&
          (bytes[1] & 0xe0) == 0xe0)) {
    return const HplInspection(
      format: 'MP3 audio',
      readiness: 'Potential MP4 audio packaging candidate if unprotected. '
          'Codec inspection and an export tool are still required.',
      detail: 'Recognized MP3 header. Protection status not determined.',
      isMedia: true,
    );
  }
  if (_signature(bytes, 0, [0x52, 0x49, 0x46, 0x46]) &&
      _signature(bytes, 8, [0x57, 0x41, 0x56, 0x45])) {
    return const HplInspection(
      format: 'WAV audio',
      readiness: 'Potentially convertible into an MP4-family container '
          'after audio encoding, if the file is unprotected.',
      detail: 'Recognized WAV container.',
      isMedia: true,
    );
  }
  if (_signature(bytes, 0, [0x66, 0x4c, 0x61, 0x43]) ||
      _signature(bytes, 0, [0x4f, 0x67, 0x67, 0x53])) {
    return HplInspection(
      format: _signature(bytes, 0, [0x66, 0x4c, 0x61, 0x43])
          ? 'FLAC audio' : 'Ogg media',
      readiness: 'Potentially convertible if unprotected; transcoding '
          'and compatible codec support are needed.',
      detail: 'Recognized media header. No conversion has been attempted.',
      isMedia: true,
    );
  }
  if (_signature(bytes, 0, [0x25, 0x50, 0x44, 0x46])) {
    return const HplInspection(
      format: 'PDF document',
      readiness: 'Not an audio/video file for direct MP4 conversion.',
      detail: 'PDF document, not playable media.',
      isMedia: false,
    );
  }
  if (_signature(bytes, 0, [0x50, 0x4b, 0x03, 0x04])) {
    return HplInspection(
      format: lower.endsWith('.epub') ? 'EPUB book' : 'ZIP-based archive',
      readiness: 'Not directly convertible to MP4 as an audio/video track.',
      detail: 'Archive header detected. This tool does not unpack '
          'other apps\' protected downloads.',
      isMedia: false,
    );
  }
  return const HplInspection(
    format: 'Unknown or inaccessible media format',
    readiness: 'Cannot establish MP4 compatibility from this file header.',
    detail: 'May be proprietary, protected, unsupported or an ordinary '
        'format that needs a more capable inspector. No decryption attempted.',
    isMedia: false,
  );
}
