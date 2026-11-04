import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'tv_remote_controller.dart';
import 'phone_sound_meter.dart';
import 'lg_voice_search.dart';

/// Single-screen TV remote with an in-place touchpad/directional-pad toggle.
class LgCompactRemote extends StatefulWidget {
  const LgCompactRemote({super.key, required this.client,
    required this.device, required this.onError});
  final TvRemoteController client;
  final Object device;
  final ValueChanged<String> onError;
  @override
  State<LgCompactRemote> createState() => _LgCompactRemoteState();
}

class _LgCompactRemoteState extends State<LgCompactRemote> {
  Timer? _timer;
  final _typing = TextEditingController();
  List<({String id, String title})> _apps = [];
  String? _appId;
  String? _channel;
  int? _volume;
  bool _muted = false;
  bool _mediaPlaying = true;
  bool _mediaBusy = false;
  bool _voiceSearchOpen = false;
  bool _arrowsMode = false;
  bool _repeatBusy = false;
  Timer? _directionRepeat;
  DateTime _lastPan = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    unawaited(_loadApps());
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 12),
        (_) => unawaited(_refresh()));
  }

  Future<void> _run(Future<void> Function() command) async {
    try {
      await command();
    } catch (error) {
      if (mounted) {
        widget.onError(error.toString()
            .replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> _toggleMedia() async {
    if (_mediaBusy || !widget.client.connected) return;
    setState(() => _mediaBusy = true);
    try {
      // TVs may not expose actual Netflix/YouTube playback state. Keep one
      // button and alternate distinct commands only after a successful call.
      await widget.client.button(_mediaPlaying ? 'PAUSE' : 'PLAY');
      if (mounted) setState(() => _mediaPlaying = !_mediaPlaying);
    } catch (error) {
      if (mounted) {
        widget.onError(error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => _mediaBusy = false);
    }
  }

  Future<void> _loadApps() async {
    try {
      final apps = await widget.client.apps();
      if (mounted) setState(() => _apps = apps);
    } catch (_) {
      // App listing isn't supported on every firmware.
    }
  }

  Future<void> _refresh() async {
    if (!widget.client.connected) return;
    try {
      final id = await widget.client.foregroundApp();
      if (!mounted) return;
      setState(() {
        if (id != _appId) _mediaPlaying = true;
        _appId = id;
        if (id == null || (!id.toLowerCase().contains('livetv') &&
            !id.toLowerCase().contains('broadcast'))) {
          _channel = null;
        }
      });
      if (id != null && (id.toLowerCase().contains('livetv') ||
          id.toLowerCase().contains('broadcast'))) {
        try {
          final channel = await widget.client.currentChannel();
          if (mounted) setState(() => _channel = channel);
        } catch (_) {}
      }
    } catch (_) {}
    try {
      final volume = await widget.client.volumeLevel();
      if (mounted) setState(() => _volume = volume);
    } catch (_) {}
  }

  String _appName() {
    if (_appId == null) return 'Ready';
    for (final app in _apps) {
      if (app.id == _appId) return app.title;
    }
    if (_appId!.toLowerCase().contains('hdmi')) return 'HDMI';
    return _appId!.split('.').last;
  }

  IconData _appIcon(String name) {
    final text = name.toLowerCase();
    if (text.contains('youtube')) return Icons.smart_display_outlined;
    if (text.contains('netflix')) return Icons.movie_outlined;
    if (text.contains('prime') || text.contains('disney') ||
        text.contains('apple')) {
      return Icons.live_tv_outlined;
    }
    if (text.contains('plex') || text.contains('jellyfin')) {
      return Icons.video_library_outlined;
    }
    if (text.contains('music') || text.contains('spotify')) {
      return Icons.music_note_outlined;
    }
    return Icons.apps_outlined;
  }

  List<({String id, String title})> get _favorites {
    int rank(String name) {
      const preferred = ['youtube', 'netflix', 'prime',
        'disney', 'apple tv', 'plex', 'spotify'];
      final index = preferred.indexWhere(name.toLowerCase().contains);
      return index < 0 ? 99 : index;
    }
    final items = _apps.toList()..sort((a, b) {
      final order = rank(a.title).compareTo(rank(b.title));
      return order != 0 ? order : a.title.compareTo(b.title);
    });
    return items.take(4).toList();
  }

  Widget _appButton(String title, IconData icon, VoidCallback? action) =>
      Expanded(child: InkWell(
        onTap: action,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 27),
            const SizedBox(height: 3),
            Text(title, textAlign: TextAlign.center,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11)),
          ]),
        ),
      ));

  Future<void> _openApps() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .58,
          child: Column(children: [
            Padding(padding: const EdgeInsets.all(14),
              child: Text('TV apps',
                  style: Theme.of(sheet).textTheme.titleLarge)),
            Expanded(child: ListView.builder(
              itemCount: _apps.length,
              itemBuilder: (_, i) {
                final app = _apps[i];
                return ListTile(
                  leading: Icon(_appIcon(app.title)),
                  title: Text(app.title),
                  onTap: () {
                    Navigator.pop(sheet);
                    unawaited(_run(() => widget.client.launchApp(app.id)));
                  },
                );
              },
            )),
          ]),
        ),
      ),
    );
  }

  void _stopDirectionRepeat() {
    _directionRepeat?.cancel();
    _directionRepeat = null;
  }

  void _pressDirection(String command) {
    unawaited(HapticFeedback.selectionClick());
    unawaited(_run(() => widget.client.button(command)));
  }

  void _repeatDirection(String command) {
    if (_repeatBusy || !widget.client.connected) return;
    _repeatBusy = true;
    unawaited(_run(() => widget.client.button(command))
        .whenComplete(() => _repeatBusy = false));
  }

  void _startDirectionRepeat(String command) {
    _stopDirectionRepeat();
    unawaited(HapticFeedback.selectionClick());
    _repeatDirection(command);
    _directionRepeat = Timer.periodic(
      const Duration(milliseconds: 210), (_) {
        if (!mounted || !_arrowsMode) {
          _stopDirectionRepeat();
          return;
        }
        _repeatDirection(command);
      },
    );
  }

  void _toggleNavigationMode() {
    _stopDirectionRepeat();
    setState(() => _arrowsMode = !_arrowsMode);
  }

  Widget _directionKey(String command, IconData icon, double size,
      ColorScheme scheme) {
    final isOk = command == 'ENTER';
    return Semantics(
      label: isOk ? 'OK' : command,
      button: true,
      child: GestureDetector(
        key: ValueKey('lg-dpad-${command.toLowerCase()}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _pressDirection(command),
        onLongPressStart: isOk ? null
            : (_) => _startDirectionRepeat(command),
        onLongPressEnd: isOk ? null : (_) => _stopDirectionRepeat(),
        onLongPressCancel: isOk ? null : _stopDirectionRepeat,
        child: SizedBox(
          height: size, width: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isOk ? scheme.primary : scheme.primaryContainer,
            ),
            child: Center(
              child: isOk
                  ? Text('OK', style: TextStyle(
                      fontSize: size * .25,
                      fontWeight: FontWeight.w700,
                      color: scheme.onPrimary))
                  : Icon(icon, size: size * .53,
                      color: scheme.onPrimaryContainer),
            ),
          ),
        ),
      ),
    );
  }

  Widget _directionPad(ColorScheme scheme) => LayoutBuilder(
    builder: (context, constraints) {
      // Fit five large buttons into the same space as the touchpad.
      final usable = math.min(
        constraints.maxWidth - 20, constraints.maxHeight - 20);
      final size = (usable / 3.32).clamp(34.0, 122.0).toDouble();
      final gap = (size * .16).clamp(6.0, 18.0).toDouble();
      return Center(
        child: SizedBox(
          width: size * 3 + gap * 2,
          height: size * 3 + gap * 2,
          child: Column(mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _directionKey('UP', Icons.keyboard_arrow_up_rounded,
                  size, scheme),
              SizedBox(height: gap),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _directionKey('LEFT', Icons.keyboard_arrow_left_rounded,
                    size, scheme),
                SizedBox(width: gap),
                _directionKey('ENTER', Icons.circle, size, scheme),
                SizedBox(width: gap),
                _directionKey('RIGHT', Icons.keyboard_arrow_right_rounded,
                    size, scheme),
              ]),
              SizedBox(height: gap),
              _directionKey('DOWN', Icons.keyboard_arrow_down_rounded,
                  size, scheme),
            ],
          ),
        ),
      );
    },
  );

  Future<void> _openVoiceSearch() async {
    if (!widget.client.connected) {
      widget.onError('Connect to the TV before using voice search.');
      return;
    }
    setState(() => _voiceSearchOpen = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => LgVoiceSearchSheet(
          onSend: widget.client.insertText,
        ),
      );
    } finally {
      if (mounted) setState(() => _voiceSearchOpen = false);
    }
  }

  Future<void> _openKeyboard() async {
    _typing.clear();
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(left: 16, right: 16, top: 16,
          bottom: MediaQuery.viewInsetsOf(sheet).bottom + 16),
        child: SafeArea(child: Row(children: [
          Expanded(child: TextField(
            controller: _typing, autofocus: true,
            textInputAction: TextInputAction.send,
            decoration: const InputDecoration(
              labelText: 'Send text to TV', border: OutlineInputBorder()),
            onSubmitted: (text) {
              Navigator.pop(sheet);
              unawaited(_run(() => widget.client.insertText(text)));
            },
          )),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Send text', icon: const Icon(Icons.send),
            onPressed: () {
              final text = _typing.text;
              Navigator.pop(sheet);
              unawaited(_run(() => widget.client.insertText(text)));
            },
          ),
        ])),
      ),
    );
  }

  Future<void> _moreControls() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(child: Padding(
        padding: const EdgeInsets.all(18),
        child: Wrap(alignment: WrapAlignment.center,
          spacing: 8, runSpacing: 8,
          children: [
            for (final control in [
              ('Rewind', Icons.fast_rewind, 'REWIND'),
              ('Stop', Icons.stop, 'STOP'),
              ('Forward', Icons.fast_forward, 'FASTFORWARD'),
            ])
              OutlinedButton.icon(
                icon: Icon(control.$2), label: Text(control.$1),
                onPressed: () {
                  Navigator.pop(sheet);
                  unawaited(_run(() => widget.client.button(control.$3)));
                },
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.add), label: const Text('Channel +'),
              onPressed: () {
                Navigator.pop(sheet);
                unawaited(_run(widget.client.channelUp));
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.remove), label: const Text('Channel −'),
              onPressed: () {
                Navigator.pop(sheet);
                unawaited(_run(widget.client.channelDown));
              },
            ),
          ],
        ),
      )),
    );
  }

  void _pan(DragUpdateDetails details) {
    final now = DateTime.now();
    if (now.difference(_lastPan) < const Duration(milliseconds: 24)) {
      return;
    }
    _lastPan = now;
    final dx = (details.delta.dx * 2).round();
    final dy = (details.delta.dy * 2).round();
    unawaited(_run(() => widget.client.pointerMove(dx, dy)));
  }

  Future<void> _showCaptions() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 22),
          child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Closed captions (CC)',
                style: Theme.of(sheet).textTheme.titleLarge),
              const SizedBox(height: 10),
              const Text('Live TV: All Settings → General → Accessibility '
                '→ Closed Caption. On older LG TVs, Accessibility may '
                'appear directly under All Settings.'),
              const SizedBox(height: 8),
              const Text('Netflix, Apple TV, YouTube and other streaming '
                'apps control their own subtitles during playback. '
                'This remote cannot override those app settings.'),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('lg-open-caption-settings'),
                onPressed: () {
                  Navigator.pop(sheet);
                  unawaited(_run(() => widget.client.button('SETTINGS')));
                },
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Open TV settings'),
              ),
              const SizedBox(height: 5),
              TextButton(onPressed: () => Navigator.pop(sheet),
                  child: const Text('Close')),
            ],
          ),
        )),
      ),
    );
  }

  Widget _actionIcon(String name, IconData icon, VoidCallback action) =>
      IconButton.outlined(
        tooltip: name, icon: Icon(icon), onPressed: action,
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final tight = box.maxHeight < 500;
      final scheme = Theme.of(context).colorScheme;
      return Column(children: [
        Row(children: [
          const Icon(Icons.graphic_eq, size: 17),
          const SizedBox(width: 7),
          Expanded(child: Text(_channel == null
                  ? 'Now: ${_appName()}'
                  : 'Now: ${_appName()} · $_channel',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall)),
          if (_volume != null)
            Text('Vol $_volume',
                style: Theme.of(context).textTheme.labelSmall),
          PhoneSoundLevelInline(
            key: const ValueKey('lg-phone-sound-meter'),
            enabled: !_voiceSearchOpen,
          ),
          IconButton(
            iconSize: 19, tooltip: 'Refresh now playing',
            onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ]),
        SizedBox(height: tight ? 0 : 6),
        Row(children: [
          if (_apps.isEmpty)
            _appButton('Home', Icons.home_outlined,
              () => unawaited(_run(() => widget.client.button('HOME')))),
          for (final app in _favorites)
            _appButton(app.title, _appIcon(app.title),
              () => unawaited(_run(
                  () => widget.client.launchApp(app.id)))),
          _appButton('Apps', Icons.grid_view_rounded,
              _apps.isEmpty ? null : _openApps),
        ]),
        SizedBox(height: tight ? 4 : 8),
        Expanded(child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: .30),
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(23),
          ),
          child: _arrowsMode
              ? _directionPad(scheme)
              : Semantics(
                  label: widget.client.pointerIsRelative
                      ? 'TV touchpad. Swipe to move pointer and tap to click.'
                      : 'TV touchpad. Swipe for arrow navigation and tap for OK.',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: _pan,
                    onTap: () => unawaited(
                        _run(widget.client.pointerClick)),
                    child: Center(child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.touch_app_outlined, size: 32),
                        const SizedBox(height: 7),
                        const Text('Touchpad',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(widget.client.pointerIsRelative
                            ? 'Swipe to browse · Tap to click'
                            : 'Swipe for arrows · Tap for OK',
                            style: const TextStyle(fontSize: 12)),
                      ],
                    )),
                  ),
                ),
        )),
        SizedBox(height: tight ? 5 : 9),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _actionIcon('Home', Icons.home_outlined, () =>
            unawaited(_run(() => widget.client.button('HOME')))),
          _actionIcon('Back', Icons.arrow_back, () =>
            unawaited(_run(() => widget.client.button('BACK')))),
          IconButton.filledTonal(
            key: const ValueKey('lg-navigation-mode-toggle'),
            tooltip: _arrowsMode ? 'Touchpad' : 'Arrows and OK',
            icon: Icon(_arrowsMode
                ? Icons.touch_app_outlined : Icons.gamepad_outlined),
            onPressed: _toggleNavigationMode,
          ),
          _actionIcon('Keyboard', Icons.keyboard_outlined, _openKeyboard),
          _actionIcon('Voice search', Icons.mic_none, _openVoiceSearch),
          _actionIcon('More controls', Icons.more_horiz, _moreControls),
        ]),
        SizedBox(height: tight ? 2 : 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          _actionIcon('Volume down', Icons.volume_down_outlined, () =>
            unawaited(_run(widget.client.volumeDown))),
          _actionIcon(_muted ? 'Unmute' : 'Mute',
              _muted ? Icons.volume_up_outlined : Icons.volume_off_outlined,
              () => unawaited(_run(() async {
                await widget.client.mute(!_muted);
                if (mounted) setState(() => _muted = !_muted);
              }))),
          _actionIcon('Volume up', Icons.volume_up_outlined, () =>
            unawaited(_run(widget.client.volumeUp))),
          IconButton.outlined(
            key: const ValueKey('lg-closed-captions'),
            tooltip: 'Closed captions (CC)',
            onPressed: _showCaptions,
            icon: const Text('CC',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          IconButton.outlined(
            key: const ValueKey('lg-media-play-pause'),
            tooltip: _mediaPlaying ? 'Pause / Play' : 'Play / Pause',
            onPressed: _mediaBusy ? null : () => unawaited(_toggleMedia()),
            icon: Icon(_mediaPlaying ? Icons.pause : Icons.play_arrow),
          ),
        ]),
      ]);
    },
  );

  @override
  void dispose() {
    _timer?.cancel();
    _stopDirectionRepeat();
    _typing.dispose();
    super.dispose();
  }
}
