import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'computer_store.dart';
import 'ssh_command_queue.dart';
import 'phone_ssh_keys.dart';
import 'ssh_host_trust.dart';
import 'ubuntu_install_validation.dart';

/// Submit the entire multiline script with one SSH write. A PTY's Enter
/// key is CR, not LF; preserve every blank line and append one final Enter
/// only when the pasted script does not already end with a newline.
String prepareSshTerminalInput(String input) {
  final normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalized.isEmpty) return '';
  final terminated = normalized.endsWith('\n')
      ? normalized : '$normalized\n';
  return terminated.replaceAll('\n', '\r');
}

/// Newline-delimited scripts use an independent SSH exec channel.
bool isSshScriptInput(String input) =>
    input.contains('\n') || input.contains('\r');

String prepareSshScriptInput(String input) {
  final normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalized.trim().isEmpty) return '';
  return normalized.endsWith('\n') ? normalized : '$normalized\n';
}

/// SSH exec carries the script in a quoted Bash argument, not PTY keystrokes
/// or stdin. This preserves blank lines and leaves stdin available for sudo.
String prepareSshScriptCommand(String input) {
  final script = prepareSshScriptInput(input);
  if (script.isEmpty) return '';
  final quoted = script.replaceAll("'", "'\"'\"'");
  return "bash -e -c '$quoted'";
}

/// Convert PTY carriage returns to visible line breaks. LF after CR must
/// be ignored even when CR and LF arrive in separate SSH network packets.
class SshTerminalOutputFormatter {
  bool _lastWasCr = false;

  String format(String chunk) {
    final buffer = StringBuffer();
    for (final rune in chunk.runes) {
      if (rune == 13) {
        buffer.write('\n');
        _lastWasCr = true;
      } else if (rune == 10) {
        if (!_lastWasCr) buffer.write('\n');
        _lastWasCr = false;
      } else {
        _lastWasCr = false;
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString()
        .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll(RegExp(r'\x1B\][^\x07]*(?:\x07|\x1B\\)'), '');
  }

  void reset() => _lastWasCr = false;
}

/// SSH is intentionally limited to private LAN addresses. Agent pairings and
/// SSH credentials are separate; nothing is uploaded or saved as shell history.
class SshTerminalScreen extends StatefulWidget {
  const SshTerminalScreen({super.key});

  @override
  State<SshTerminalScreen> createState() => _SshTerminalScreenState();
}

class _SshCommandCard {
  _SshCommandCard(this.command, String loginUser)
      : cleaner = SshCommandOutputCleaner(loginUser);
  final SshQueuedCommand command;
  final SshCommandOutputCleaner cleaner;
  String output = '';
  String status = 'Queued';
  int? exitCode;
}

class _SshTerminalScreenState extends State<SshTerminalScreen> {
  final _host = TextEditingController();
  final _username = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _password = TextEditingController();
  final _command = TextEditingController();
  final _promptResponse = TextEditingController();
  final _outputScroll = ScrollController();
  final _outputFormatter = SshTerminalOutputFormatter();
  final _keyStore = PhoneSshKeyStore();
  final _trust = SshHostTrustStore();
  List<SavedComputer> _computers = const [];
  List<SavedSshKey> _keys = const [];
  String? _selectedKey;
  bool _useKey = true;
  bool _connecting = false;
  bool _connected = false;
  bool _closedByUser = false;
  String _output = '';
  String? _error;
  SSHClient? _client;
  SSHSession? _shell;
  final List<_SshCommandCard> _queue = [];
  int _queueIndex = -1;
  bool _queueActive = false;
  bool _queueWaitingForShell = false;
  bool _editorCollapsed = false;
  bool _hidePromptResponse = true;
  SshQueueOutputDecoder? _queueDecoder;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final computers = await ComputerStore().read();
      final keys = await _keyStore.listKeys();
      final selected = await _keyStore.selectedId();
      if (!mounted) return;
      setState(() {
        _computers = computers;
        _keys = keys;
        _selectedKey = selected;
        _useKey = keys.isNotEmpty;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Unable to load SSH settings.');
    }
  }

  void _selectComputer(SavedComputer computer) {
    if (_connecting || _connected) return;
    _host.text = computer.host;
    setState(() => _error = null);
  }

  Future<String?> _inspectHostKey(String host, int port, String username)
      async {
    // Refuse the first host key BEFORE sending a password or private key.
    // The observed fingerprint can then be checked by the user out of band.
    String? observed;
    final socket = await SSHSocket.connect(host, port)
        .timeout(const Duration(seconds: 8));
    final probe = SSHClient(
      socket,
      username: username,
      handshakeTimeout: const Duration(seconds: 12),
      authTimeout: const Duration(seconds: 10),
      onVerifyHostKey: (_, fingerprint) {
        observed = utf8.decode(fingerprint, allowMalformed: true);
        return false;
      },
    );
    try {
      await probe.authenticated.timeout(const Duration(seconds: 16));
    } catch (_) {
      // Expected rejection: the first connection is ONLY an identity probe.
    } finally {
      await probe.close();
    }
    return observed;
  }

  Future<bool> _confirmFingerprint(String host, int port,
      String fingerprint) async {
    if (!mounted) return false;
    return await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Verify SSH host identity'),
        content: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$host:$port'),
            const SizedBox(height: 10),
            SelectableText(fingerprint, style:
                const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 10),
            const Text('Compare this fingerprint with the one displayed '
                'by the computer itself before trusting the connection. '
                'TapTether pins it only after successful login. '
                'A changed key will be blocked later.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('ssh-confirm-fingerprint'),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Matches my computer')),
        ],
      ),
    ) ?? false;
  }

  Future<void> _connect() async {
    if (_connecting || _connected) return;
    final host = _host.text.trim();
    final username = _username.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (!validUbuntuLanIp(host) || port == null ||
        port < 1 || port > 65535 ||
        !RegExp(r'^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}$').hasMatch(username)) {
      setState(() => _error = 'Enter a private LAN IP address, SSH '
          'username and port (1–65535).');
      return;
    }
    if (_useKey && _selectedKey == null) {
      setState(() => _error = 'Create or select a phone SSH key first.');
      return;
    }
    if (!_useKey && _password.text.isEmpty) {
      setState(() => _error = 'Enter the SSH account password.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
      _output = '';
      _outputFormatter.reset();
      _queue.clear();
      _queueIndex = -1;
      _queueActive = false;
      _queueDecoder = null;
      _closedByUser = false;
    });
    SSHClient? candidate;
    try {
      final saved = await _trust.trustedFingerprint(host, port: port);
      var expected = saved;
      if (expected == null) {
        final fingerprint = await _inspectHostKey(host, port, username);
        if (fingerprint == null ||
            !SshHostTrustStore.validFingerprint(fingerprint)) {
          throw StateError('Unable to verify the server SSH identity.');
        }
        if (!await _confirmFingerprint(host, port, fingerprint)) return;
        expected = fingerprint;
      }
      final identities = _useKey
          ? await _keyStore.authenticationIdentities(id: _selectedKey)
          : null;
      final password = _useKey ? null : _password.text;
      final socket = await SSHSocket.connect(host, port)
          .timeout(const Duration(seconds: 8));
      String? observed;
      candidate = SSHClient(
        socket,
        username: username,
        identities: identities,
        onPasswordRequest: password == null ? null : () => password,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
        onVerifyHostKey: (_, fingerprint) {
          observed = utf8.decode(fingerprint, allowMalformed: true);
          return observed == expected;
        },
      );
      try {
        await candidate.authenticated.timeout(const Duration(seconds: 25));
      } catch (_) {
        if (observed != null && observed != expected) {
          throw StateError('SSH host identity changed. Connection blocked.');
        }
        throw StateError('SSH login failed. Check username, password or '
            'authorized phone key.');
      }
      if (!mounted) return;
      await _trust.rememberAuthenticated(host, expected, port: port);
      final shell = await candidate.shell(
          pty: const SSHPtyConfig());
      if (!mounted) {
        shell.close();
        return;
      }
      _password.clear();
      _client = candidate;
      candidate = null;
      _shell = shell;
      _stdout = utf8.decoder.bind(shell.stdout).listen(_onShellOutput,
          onError: (_) => _append('\n[SSH output interrupted]\n'));
      _stderr = utf8.decoder.bind(shell.stderr).listen(_onShellOutput,
          onError: (_) {});
      setState(() {
        _connected = true;
        _output = 'Connected to $username@$host:$port\n';
      });
      // The app renders the command in its own card. Avoid PTY echo
      // duplicating the long completion-marker wrapper in visible output.
      shell.write(Uint8List.fromList(utf8.encode('stty -echo\r')));
      unawaited(shell.done.then((_) {
        if (mounted && !_closedByUser) {
          _append('\n[SSH session ended]\n');
          setState(() => _connected = false);
        }
      }).catchError((Object _) {
        if (mounted && !_closedByUser) {
          _append('\n[SSH connection lost]\n');
          setState(() => _connected = false);
        }
      }));
    } on StateError catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Unable to connect. Check Wi-Fi, port, and SSH service.');
      }
    } finally {
      await candidate?.close();
      if (mounted) {
        setState(() => _connecting = false);
      }
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_outputScroll.hasClients) return;
      final position = _outputScroll.position;
      if (position.extentAfter < 250) {
        _outputScroll.jumpTo(position.maxScrollExtent);
      }
    });
  }

  void _append(String text) {
    if (!mounted || _closedByUser) return;
    setState(() {
      _output += text;
      if (_output.length > 32000) {
        _output = _output.substring(_output.length - 32000);
      }
    });
    _scrollToEnd();
  }

  void _onShellOutput(String text) {
    if (!mounted || _closedByUser) return;
    final formatted = _outputFormatter.format(text);
    if (_queueActive && _queueIndex >= 0 && _queueIndex < _queue.length) {
      if (_queueWaitingForShell) {
        _appendQueueOutput(formatted);
        return;
      }
      final decoder = _queueDecoder;
      if (decoder != null) {
        final chunk = decoder.add(formatted);
        if (chunk.output.isNotEmpty) _appendQueueOutput(chunk.output);
        if (chunk.exitCode != null) {
          setState(() {
            final item = _queue[_queueIndex];
            final trailing = item.cleaner.flush();
            if (trailing.isNotEmpty) item.output += trailing;
            item.exitCode = chunk.exitCode;
            item.status = chunk.exitCode == 0 ? 'Completed' : 'Failed';
            _queueIndex = -1;
            _queueDecoder = null;
          });
          _runNextQueueCommand();
        }
        return;
      }
    }
    _append(formatted);
  }

  void _appendQueueOutput(String text) {
    if (!mounted || text.isEmpty || _queueIndex < 0 ||
        _queueIndex >= _queue.length) {
      return;
    }
    final cleaned = _queue[_queueIndex].cleaner.add(text);
    if (cleaned.isEmpty) return;
    setState(() {
      final card = _queue[_queueIndex];
      card.output += cleaned;
      if (card.output.length > 32000) {
        card.output = card.output.substring(card.output.length - 32000);
      }
    });
    _scrollToEnd();
  }

  void _send() {
    final shell = _shell;
    if (!_connected || shell == null || _queueActive) return;
    final input = _command.text;
    if (input.trim().isEmpty) return;
    if (!isSshScriptInput(input)) {
      _append('\n> $input\n');
      shell.write(Uint8List.fromList(utf8.encode(
          prepareSshTerminalInput(input))));
      _command.clear();
      return;
    }

    List<SshQueuedCommand> commands;
    try {
      commands = parseSshCommandQueue(input);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    if (commands.isEmpty) return;
    if (commands.length > 150) {
      setState(() => _error = 'Limit Run All to 150 commands per batch.');
      return;
    }
    setState(() {
      _error = null;
      _queue.clear();
      _queue.addAll(commands.map((command) =>
          _SshCommandCard(command, _username.text.trim())));
      _queueActive = true;
      _editorCollapsed = true;
      _queueIndex = -1;
      _queueWaitingForShell = false;
    });
    _command.clear();
    _runNextQueueCommand();
  }

  void _runNextQueueCommand() {
    final shell = _shell;
    if (!mounted || !_connected || !_queueActive || shell == null) return;
    final next = _queue.indexWhere((item) => item.status == 'Queued');
    if (next < 0) {
      setState(() {
        _queueActive = false;
        _queueIndex = -1;
        _queueWaitingForShell = false;
        _queueDecoder = null;
      });
      return;
    }
    final current = _queue[next];
    setState(() {
      _queueIndex = next;
      current.status = 'Running';
    });

    if (current.command.shellTransition) {
      // sudo su - (and similar commands) opens a *new* interactive shell.
      // There is no exit marker until that child shell quits. Do not push
      // subsequent commands into a password prompt. Wait for confirmation.
      setState(() {
        _queueWaitingForShell = true;
        current.status = 'Confirm new shell';
      });
      shell.write(Uint8List.fromList(
          utf8.encode(prepareSshTerminalInput(current.command.command))));
      return;
    }

    final random = Random.secure();
    final token = List.generate(16, (_) =>
        random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _queueDecoder = SshQueueOutputDecoder(token);
    final wrapped = wrapSshQueuedCommand(current.command.command, token);
    shell.write(Uint8List.fromList(utf8.encode('$wrapped\r')));
  }

  void _continueAfterShellSwitch() {
    if (!_queueActive || !_queueWaitingForShell || _queueIndex < 0) return;
    setState(() {
      _queue[_queueIndex].status = 'Shell changed (confirmed)';
      _queueIndex = -1;
      _queueWaitingForShell = false;
    });
    _runNextQueueCommand();
  }

  void _stopQueue({bool sendInterrupt = true}) {
    if (!_queueActive) return;
    if (sendInterrupt && _connected && !_queueWaitingForShell) {
      _signal([3]);
    }
    setState(() {
      for (final item in _queue) {
        if (item.status == 'Queued') item.status = 'Skipped';
        if (item.status == 'Running' ||
            item.status == 'Confirm new shell') {
          item.status = 'Stopped';
        }
      }
      _queueActive = false;
      _queueIndex = -1;
      _queueDecoder = null;
      _queueWaitingForShell = false;
    });
  }

  void _replyToPrompt() {
    if (!_connected || !_queueActive || _shell == null) return;
    final input = _promptResponse.text;
    if (input.isEmpty) return;
    _shell!.write(Uint8List.fromList(utf8.encode('$input\r')));
    // Never put passwords or other prompt replies into the output or cards.
    _promptResponse.clear();
  }

  String _allVisibleOutput() {
    final buffer = StringBuffer(_output);
    for (var i = 0; i < _queue.length; i++) {
      final item = _queue[i];
      buffer.writeln();
      if (item.command.section.isNotEmpty &&
          (i == 0 || item.command.section != _queue[i - 1].command.section)) {
        buffer.writeln('# ${item.command.section}');
      }
      buffer.writeln('[${i + 1}/${_queue.length}] ${item.command.command}');
      if (item.output.isNotEmpty) buffer.write(item.output);
      buffer.writeln('\n[${item.status}${item.exitCode == null ? '' : ' · exit ${item.exitCode}'}]');
    }
    return buffer.toString();
  }

  Future<void> _copyOutput() async {
    final output = _allVisibleOutput();
    if (output.trim().isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: output));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('SSH output copied'),
          duration: Duration(seconds: 2),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Unable to copy SSH output'),
        ));
      }
    }
  }

  Future<void> _copyCommandOutput(_SshCommandCard item) async {
    final text = '${item.command.command}\n${item.output}';
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Command output copied'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  void _signal(List<int> bytes) {
    if (_connected) _shell?.write(Uint8List.fromList(bytes));
  }

  Future<void> _disconnect() async {
    _closedByUser = true;
    _stopQueue(sendInterrupt: false);
    final shell = _shell;
    final client = _client;
    _shell = null;
    _client = null;
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
    shell?.close();
    await client?.close();
    _password.clear();
    _command.clear();
    if (mounted) {
      setState(() {
        _connected = false;
        _output += '\n[Disconnected]\n';
      });
    }
  }

  @override
  void dispose() {
    _closedByUser = true;
    _stdout?.cancel();
    _stderr?.cancel();
    _shell?.close();
    unawaited(_client?.close() ?? Future<void>.value());
    _host.dispose();
    _username.dispose();
    _port.dispose();
    _password.dispose();
    _command.dispose();
    _promptResponse.dispose();
    _outputScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _connected || _connecting;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SSH'),
        actions: [
          if (_connected)
            TextButton(onPressed: _disconnect,
                child: const Text('Disconnect')),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          if (!_connected)
            Flexible(
              fit: FlexFit.loose,
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(16),
                children: [
                  const Text('Connect to a computer on your private network. '
                      'No cloud account or stored password.'),
                  if (_computers.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    PopupMenuButton<SavedComputer>(
                      key: const ValueKey('ssh-saved-hosts'),
                      enabled: !active,
                      onSelected: _selectComputer,
                      itemBuilder: (_) => [
                        for (final pc in _computers)
                          PopupMenuItem(
                              value: pc,
                              child: Text('${pc.name} · ${pc.host}')),
                      ],
                      child: const ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.devices_outlined),
                        title: Text('Choose saved computer'),
                        trailing: Icon(Icons.expand_more),
                      ),
                    ),
                  ],
                  Row(children: [
                    Expanded(flex: 3, child: TextField(
                      key: const ValueKey('ssh-host'),
                      controller: _host,
                      enabled: !active,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'LAN IP',
                        hintText: '192.168.68.90',
                      ),
                    )),
                    const SizedBox(width: 10),
                    Expanded(child: TextField(
                      key: const ValueKey('ssh-port'),
                      controller: _port,
                      enabled: !active,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Port'),
                    )),
                  ]),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey('ssh-username'),
                    controller: _username,
                    enabled: !active,
                    autocorrect: false,
                    decoration: const InputDecoration(
                        labelText: 'SSH username'),
                  ),
                  const SizedBox(height: 6),
                  SegmentedButton<bool>(
                    key: const ValueKey('ssh-login-method'),
                    segments: const [
                      ButtonSegment(value: true, label: Text('Phone key'),
                          icon: Icon(Icons.key_outlined)),
                      ButtonSegment(value: false, label: Text('Password'),
                          icon: Icon(Icons.password_outlined)),
                    ],
                    selected: {_useKey},
                    onSelectionChanged: active ? null : (next) =>
                        setState(() => _useKey = next.first),
                  ),
                  if (_useKey) ...[
                    if (_keys.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 9),
                        child: Text('No phone SSH key. Create or import '
                            'one under Settings & More → SSH Keys.'),
                      )
                    else
                      DropdownButtonFormField<String>(
                        key: const ValueKey('ssh-key-choice'),
                        initialValue: _selectedKey,
                        items: [
                          for (final key in _keys)
                            DropdownMenuItem(
                              value: key.id,
                              child: Text(key.name),
                            ),
                        ],
                        onChanged: active ? null : (id) =>
                            setState(() => _selectedKey = id),
                        decoration: const InputDecoration(
                            labelText: 'Phone SSH key'),
                      ),
                  ] else
                    TextField(
                      key: const ValueKey('ssh-password'),
                      controller: _password,
                      enabled: !active,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                          labelText: 'SSH password (not saved)'),
                    ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    key: const ValueKey('ssh-connect'),
                    onPressed: active ? null : _connect,
                    icon: const Icon(Icons.terminal),
                    label: Text(_connecting ? 'Connecting…' : 'Connect SSH'),
                  ),
                  if (_connecting) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!,
                        style: TextStyle(color:
                            Theme.of(context).colorScheme.error)),
                    ),
                ],
              ),
            ),
          if (_connected || _output.isNotEmpty || _queue.isNotEmpty)
            Expanded(child: ListView(
              key: const ValueKey('ssh-history'),
              controller: _outputScroll,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              children: [
                if (_queue.isEmpty)
                  Container(
                    color: Theme.of(context).colorScheme.inverseSurface,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(_output,
                      key: const ValueKey('ssh-output'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onInverseSurface,
                        fontFamily: 'monospace', fontSize: 13, height: 1.3)),
                  )
                else ...[
                  ExpansionTile(
                    key: const ValueKey('ssh-session-log'),
                    title: const Text('Session log'),
                    subtitle: const Text('SSH welcome and shell output'),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        width: double.infinity,
                        color: Theme.of(context).colorScheme.inverseSurface,
                        child: SelectableText(_output,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: Theme.of(context).colorScheme
                                .onInverseSurface)),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 8),
                    child: Row(children: [
                      Expanded(child: Text('Commands · ${_queue.where((item) =>
                              item.status != 'Queued' &&
                              item.status != 'Running' &&
                              item.status != 'Confirm new shell').length}/${_queue.length}',
                          style: Theme.of(context).textTheme.labelMedium)),
                      if (_queueActive)
                        const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                    ]),
                  ),
                  for (var i = 0; i < _queue.length; i++) ...[
                    if (_queue[i].command.section.isNotEmpty &&
                        (i == 0 ||
                        _queue[i].command.section !=
                            _queue[i - 1].command.section))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 10, 8, 3),
                        child: Text(_queue[i].command.section,
                            style: Theme.of(context).textTheme.titleSmall),
                      ),
                    Card(
                      key: ValueKey('ssh-queue-command-$i'),
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(
                                _queue[i].status == 'Completed'
                                    ? Icons.check_circle_outline
                                    : _queue[i].status == 'Failed'
                                        ? Icons.error_outline
                                        : _queue[i].status == 'Running' ||
                                          _queue[i].status ==
                                              'Confirm new shell'
                                            ? Icons.pending_outlined
                                            : Icons.circle_outlined,
                                size: 19,
                                color: _queue[i].status == 'Failed'
                                    ? Theme.of(context).colorScheme.error
                                    : Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Text('Command ${i + 1}',
                                  style: Theme.of(context)
                                      .textTheme.labelLarge),
                              const Spacer(),
                              Text(_queue[i].exitCode == null
                                      ? _queue[i].status
                                      : 'Exit ${_queue[i].exitCode}',
                                  style: Theme.of(context)
                                      .textTheme.labelSmall),
                              IconButton(
                                key: ValueKey('ssh-copy-command-$i'),
                                tooltip: 'Copy command and output',
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    _copyCommandOutput(_queue[i]),
                                icon: const Icon(Icons.copy_outlined,
                                    size: 17),
                              ),
                            ]),
                            SelectableText(_queue[i].command.command,
                              style: Theme.of(context)
                                  .textTheme.bodyMedium?.copyWith(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w600,
                                  )),
                            if (_queue[i].output.isNotEmpty) ...[
                              const Divider(height: 13),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(9),
                                color: Theme.of(context)
                                    .colorScheme.surfaceContainerHighest,
                                child: SelectableText(_queue[i].output,
                                  key: ValueKey('ssh-command-output-$i'),
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12.5,
                                    height: 1.3,
                                  )),
                              ),
                            ] else if (_queue[i].status == 'Running')
                              Text('Waiting for command output…',
                                  style: Theme.of(context)
                                      .textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            )),
          if (_connected || _output.isNotEmpty || _queue.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(children: [
                if (_connected && !_queueActive) ...[
                  TextButton(onPressed: () => _signal([3]),
                      child: const Text('Ctrl+C')),
                  TextButton(onPressed: () => _signal([9]),
                      child: const Text('Tab')),
                ],
                if (_queueActive)
                  TextButton.icon(
                    key: const ValueKey('ssh-stop-queue'),
                    onPressed: _stopQueue,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop'),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: _queueActive ? null : () => setState(() {
                    _output = '';
                    _queue.clear();
                  }),
                  child: const Text('Clear'),
                ),
                TextButton.icon(
                  key: const ValueKey('ssh-copy-output'),
                  onPressed: _output.isEmpty && _queue.isEmpty
                      ? null : _copyOutput,
                  icon: const Icon(Icons.copy_outlined, size: 17),
                  label: const Text('Copy all'),
                ),
              ]),
            ),
          if (_connected) ...[
            if (_queueActive) ...[
              if (_queueWaitingForShell)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('ssh-confirm-shell-switch'),
                    onPressed: _continueAfterShellSwitch,
                    icon: const Icon(Icons.terminal),
                    label: const Text(
                        'Continue when new shell prompt appears'),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 1, 12, 6),
                child: Row(children: [
                  Expanded(child: TextField(
                    key: const ValueKey('ssh-queue-prompt-response'),
                    controller: _promptResponse,
                    obscureText: _hidePromptResponse,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _replyToPrompt(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Answer sudo / interactive prompt',
                      suffixIcon: IconButton(
                        tooltip: 'Show or hide response',
                        onPressed: () => setState(() =>
                            _hidePromptResponse = !_hidePromptResponse),
                        icon: Icon(_hidePromptResponse
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                      ),
                    ),
                  )),
                  TextButton(
                    key: const ValueKey('ssh-queue-reply'),
                    onPressed: _replyToPrompt,
                    child: const Text('Reply'),
                  ),
                ]),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(children: [
                Expanded(child: Text(
                    _queueActive ? 'Running commands in current shell'
                        : 'SSH command input',
                    style: Theme.of(context).textTheme.labelMedium)),
                TextButton.icon(
                  key: const ValueKey('ssh-toggle-editor'),
                  onPressed: _queueActive ? null : () => setState(() =>
                      _editorCollapsed = !_editorCollapsed),
                  icon: Icon(_editorCollapsed
                      ? Icons.expand_less : Icons.expand_more),
                  label: Text(_editorCollapsed
                      ? 'New commands' : 'Collapse'),
                ),
              ]),
            ),
            if (!_editorCollapsed && !_queueActive)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: TextField(
                      key: const ValueKey('ssh-command'),
                      controller: _command,
                      minLines: 2,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.none,
                      decoration: const InputDecoration(
                        hintText: 'Paste commands, one per line',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    )),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('ssh-send'),
                      onPressed: _send,
                      child: const Text('Run all'),
                    ),
                  ],
                ),
              ),
          ],
        ]),
      ),
    );
  }
}
