import 'dart:async';
import 'package:flutter/material.dart';
import 'lg_webos_client.dart';

/// Single-screen TV remote. Optional actions open overlays, never add rows.
class LgCompactRemote extends StatefulWidget {
  const LgCompactRemote({super.key, required this.client,
    required this.device, required this.onError});
  final LgWebOsClient client;
  final LgTvDevice device;
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
      if (mounted) widget.onError(error.toString()
          .replaceFirst('Bad state: ', ''));
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
        text.contains('apple')) return Icons.live_tv_outlined;
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

  Future<void> _openDpad() async {
    await showDialog<void>(
      context: context,
      builder: (dialog) {
        Widget key(String key, IconData icon) => IconButton.filledTonal(
          tooltip: key, iconSize: 30, icon: Icon(icon),
          onPressed: () => unawaited(_run(
              () => widget.client.button(key))),
        );
        return AlertDialog(
          title: const Text('Navigation'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            key('UP', Icons.keyboard_arrow_up),
            Row(mainAxisSize: MainAxisSize.min, children: [
              key('LEFT', Icons.keyboard_arrow_left),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 10),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(20)),
                  onPressed: () => unawaited(_run(
                      () => widget.client.button('ENTER'))),
                  child: const Text('OK'),
                )),
              key('RIGHT', Icons.keyboard_arrow_right),
            ]),
            key('DOWN', Icons.keyboard_arrow_down),
          ]),
          actions: [TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Close'),
          )],
        );
      },
    );
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
          Expanded(child: Text('Now: ' + _appName() +
                  (_channel == null ? '' : ' · ' + _channel!),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall)),
          if (_volume != null)
            Text('Vol ' + _volume.toString(),
                style: Theme.of(context).textTheme.labelSmall),
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
        Expanded(child: Semantics(
          label: 'LG TV touchpad. Swipe to browse and tap to click.',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: _pan,
            onTap: () => unawaited(_run(widget.client.pointerClick)),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: .30),
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(23),
              ),
              child: const Center(child: Column(
                mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.touch_app_outlined, size: 32),
                  SizedBox(height: 7),
                  Text('Touchpad',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  SizedBox(height: 4),
                  Text('Swipe to browse · Tap to click',
                      style: TextStyle(fontSize: 12)),
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
            tooltip: 'Arrows and OK',
            icon: const Icon(Icons.gamepad_outlined),
            onPressed: _openDpad,
          ),
          _actionIcon('Keyboard', Icons.keyboard_outlined, _openKeyboard),
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
          _actionIcon('Play', Icons.play_arrow, () =>
            unawaited(_run(() => widget.client.button('PLAY')))),
          _actionIcon('Pause', Icons.pause, () =>
            unawaited(_run(() => widget.client.button('PAUSE')))),
        ]),
      ]);
    },
  );

  @override
  void dispose() {
    _timer?.cancel();
    _typing.dispose();
    super.dispose();
  }
}
