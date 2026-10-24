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
  _SshCommandCard(this.command);
  final SshQueuedCommand command;
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

  void _append(String text) {
    if (!mounted || _closedByUser) return;
    // Simple readable shell output; full-screen TUI apps still require
    // terminal cursor control, which this compact console does not emulate.
    final safe = _outputFormatter.format(text);
    setState(() {
      _output += safe;
      if (_output.length > 32000) {
        _output = _output.substring(_output.length - 32000);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _outputScroll.hasClients) {
        _outputScroll.jumpTo(_outputScroll.position.maxScrollExtent);
      }
    });
  }

  /// Single commands stay in the interactive shell. Multiline scripts
  /// bypass the PTY so their blank lines, quotes and heredocs survive.
  void _send() {
    final shell = _shell;
    if (!_connected || shell == null || _scriptBusy) return;
    final command = _command.text;
    if (command.trim().isEmpty) return;
    if (isSshScriptInput(command)) {
      unawaited(_runScript(command));
      return;
    }
    shell.write(Uint8List.fromList(utf8.encode(
        prepareSshTerminalInput(command))));
    _command.clear();
  }

  Future<void> _runScript(String source) async {
    final client = _client;
    if (!_connected || client == null || _scriptBusy) return;
    final script = prepareSshScriptInput(source);
    if (script.isEmpty) return;
    if (script.length > 16000) {
      _append('\n[Script too long. Maximum 16,000 characters.]\n');
      return;
    }
    setState(() {
      _scriptBusy = true;
      _scriptCanceled = false;
    });
    _append('\n[Running Bash script as SSH login user. '
        'Sudo may request a password below.]\n');
    SSHSession? process;
    try {
      // Script is passed as ONE safely quoted exec command, not PTY
      // keystrokes. A PTY is allocated only for prompts such as sudo.
      // stdin remains open and free for interactive password responses.
      process = await client.execute(
        prepareSshScriptCommand(script),
        pty: const SSHPtyConfig(),
      ).timeout(const Duration(seconds: 15));
      _scriptSession = process;
      final stdoutDone = utf8.decoder.bind(process.stdout)
          .listen(_append).asFuture<void>();
      final stderrDone = utf8.decoder.bind(process.stderr)
          .listen(_append).asFuture<void>();
      final exitCode = await process.waitForExit(
          timeout: const Duration(minutes: 5));
      await Future.wait([stdoutDone, stderrDone])
          .timeout(const Duration(seconds: 10));
      if (!mounted || _closedByUser || _scriptCanceled) return;
      _append('\n[Script finished · exit code ${exitCode ?? "unknown"}]\n');
      if (exitCode == 0 && _command.text == source) {
        _command.clear();
      }
    } catch (_) {
      if (mounted && !_closedByUser && !_scriptCanceled) {
        _append('\n[Script failed, connection lost, or timed out. '
            'Review the output above and retry only if safe.]\n');
      }
    } finally {
      process?.close();
      _scriptSession = null;
      _scriptResponse.clear();
      if (mounted) setState(() => _scriptBusy = false);
    }
  }

  void _replyToScript() {
    final session = _scriptSession;
    final text = _scriptResponse.text;
    if (!_scriptBusy || session == null || text.isEmpty) return;
    session.stdin.add(Uint8List.fromList(utf8.encode('$text\r')));
    // Never display, cache or copy credentials typed here.
    _scriptResponse.clear();
  }

  void _cancelScript() {
    if (!_scriptBusy) return;
    _scriptCanceled = true;
    _scriptSession?.close();
    _append('\n[Script interrupted. Some commands may have run.]\n');
  }

  Future<void> _copyOutput() async {
    if (_output.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: _output));
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

  void _signal(List<int> bytes) {
    if (_connected) _shell?.write(Uint8List.fromList(bytes));
  }

  Future<void> _disconnect() async {
    _closedByUser = true;
    _scriptCanceled = true;
    _scriptSession?.close();
    _scriptSession = null;
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
    _scriptSession?.close();
    unawaited(_client?.close() ?? Future<void>.value());
    _host.dispose();
    _username.dispose();
    _port.dispose();
    _password.dispose();
    _command.dispose();
    _scriptResponse.dispose();
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
          if (_connected || _output.isNotEmpty)
            Expanded(child: Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.inverseSurface,
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                controller: _outputScroll,
                child: SelectableText(_output,
                  key: const ValueKey('ssh-output'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onInverseSurface,
                    fontFamily: 'monospace', fontSize: 13, height: 1.35)),
              ),
            )),
          if (_connected || _output.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(children: [
                if (_connected) ...[
                  TextButton(
                    onPressed: _scriptBusy ? null : () => _signal([3]),
                    child: const Text('Ctrl+C')),
                  TextButton(
                    onPressed: _scriptBusy ? null : () => _signal([9]),
                    child: const Text('Tab')),
                ],
                TextButton(
                  onPressed: _output.isEmpty ? null : () =>
                      setState(() => _output = ''),
                  child: const Text('Clear')),
                TextButton.icon(
                  key: const ValueKey('ssh-copy-output'),
                  onPressed: _output.isEmpty ? null : _copyOutput,
                  icon: const Icon(Icons.copy_outlined, size: 17),
                  label: const Text('Copy'),
                ),
              ]),
            ),
          if (_connected) ...[
            if (_scriptBusy) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  Expanded(child: TextField(
                    key: const ValueKey('ssh-script-response'),
                    controller: _scriptResponse,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _replyToScript(),
                    decoration: const InputDecoration(
                      labelText: 'Sudo password / prompt response',
                      isDense: true,
                    ),
                  )),
                  TextButton(
                    key: const ValueKey('ssh-script-reply'),
                    onPressed: _replyToScript,
                    child: const Text('Reply'),
                  ),
                  IconButton(
                    key: const ValueKey('ssh-script-cancel'),
                    tooltip: 'Stop running script',
                    icon: const Icon(Icons.stop_circle_outlined),
                    onPressed: _cancelScript,
                  ),
                ]),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 5, 12, 7),
                child: Text('Script runs as the SSH login user, not '
                    'a prior su/root shell. Reply only to a prompt '
                    'shown in the output.',
                    style: TextStyle(fontSize: 11)),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Row(children: [
                Expanded(child: TextField(
                  key: const ValueKey('ssh-command'),
                  controller: _command,
                  minLines: 3,
                  maxLines: 7,
                  readOnly: _scriptBusy,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  decoration: const InputDecoration(
                    hintText: 'Paste commands (blank lines supported)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                )),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _command,
                  builder: (_, value, __) => FilledButton(
                    key: const ValueKey('ssh-send'),
                    onPressed: _scriptBusy ? null : _send,
                    child: Text(_scriptBusy ? 'Running…'
                        : isSshScriptInput(value.text) ? 'Run script'
                        : 'Send'),
                  ),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}
