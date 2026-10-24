/// Parse pasted terminal commands without discarding comments/blank lines.
class SshQueuedCommand {
  const SshQueuedCommand({
    required this.command,
    required this.section,
    required this.shellTransition,
  });

  final String command;
  final String section;
  final bool shellTransition;
}

bool isSshShellTransition(String input) {
  final command = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  return RegExp(
    r'^(?:sudo su(?: -| --login)?|su(?: -| - root| root)?'
    r'|sudo -i|sudo -s|sudo bash|sudo -u root -i)$',
    caseSensitive: false,
  ).hasMatch(command);
}

List<SshQueuedCommand> parseSshCommandQueue(String source) {
  final lines = source.replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n').split('\n');
  final entries = <SshQueuedCommand>[];
  var section = '';
  for (var i = 0; i < lines.length; i++) {
    var command = lines[i];
    final line = command.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      section = line.substring(1).trim();
      continue;
    }
    final heredoc = RegExp(r'''<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?''')
        .firstMatch(command);
    if (heredoc != null) {
      final closing = heredoc.group(1)!;
      var closed = false;
      while (++i < lines.length) {
        command += '\n${lines[i]}';
        if (lines[i].trim() == closing) {
          closed = true;
          break;
        }
      }
      if (!closed) {
        throw const FormatException(
            'Unclosed heredoc. Complete the block before sending.');
      }
    } else if (line.endsWith(r'\')) {
      while (command.trimRight().endsWith(r'\')) {
        i++;
        if (i >= lines.length) {
          throw const FormatException(
              'A trailing backslash needs a following command line.');
        }
        command += '\n${lines[i]}';
      }
    } else if (RegExp(r'^(?:if|for|while|until|case|function)\b')
        .hasMatch(line)) {
      throw const FormatException(
          'Compound shell blocks are not supported in Run All. '
          'Use individual lines or a complete heredoc.');
    }
    entries.add(SshQueuedCommand(
      command: command,
      section: section,
      shellTransition: isSshShellTransition(command),
    ));
  }
  return entries;
}

/// The whole command is parsed by the existing shell on one input line.
/// A random token and ASCII control delimiters distinguish true completion
/// output from the input echoed by the PTY.
String wrapSshQueuedCommand(String command, String token) {
  if (!RegExp(r'^[A-Fa-f0-9]{16,64}$').hasMatch(token)) {
    throw const FormatException('Invalid command completion token.');
  }
  final quoted = command.replaceAll("'", "'\"'\"'");
  return "eval '$quoted'; __tt_queue_rc=\$?; "
      "printf '\\036TT_DONE_$token:%s\\037\\n' "
      '"\$__tt_queue_rc"';
}

class SshQueueOutputDecoder {
  SshQueueOutputDecoder(this.token);

  final String token;
  String _pending = '';
  static const String _start = '\u001e';
  static const String _end = '\u001f';

  SshQueueOutputChunk add(String input) {
    var buffer = _pending + input;
    _pending = '';
    final out = StringBuffer();
    int? exitCode;
    final markerPrefix = '${_start}TT_DONE_$token:';

    while (buffer.isNotEmpty) {
      final start = buffer.indexOf(_start);
      if (start == -1) {
        out.write(buffer);
        break;
      }
      if (start > 0) out.write(buffer.substring(0, start));
      buffer = buffer.substring(start);
      if (markerPrefix.startsWith(buffer)) {
        _pending = buffer;
        break;
      }
      if (!buffer.startsWith(markerPrefix)) {
        out.write(_start);
        buffer = buffer.substring(1);
        continue;
      }
      final closing = buffer.indexOf(_end, markerPrefix.length);
      if (closing < 0) {
        _pending = buffer;
        break;
      }
      exitCode = int.tryParse(buffer.substring(markerPrefix.length, closing));
      if (exitCode == null) {
        out.write(buffer.substring(0, closing + 1));
      }
      buffer = buffer.substring(closing + 1);
      if (buffer.startsWith('\n')) buffer = buffer.substring(1);
    }
    return SshQueueOutputChunk(out.toString(), exitCode);
  }

  String flush() {
    final text = _pending;
    _pending = '';
    return text;
  }
}

class SshQueueOutputChunk {
  const SshQueueOutputChunk(this.output, this.exitCode);
  final String output;
  final int? exitCode;
}
