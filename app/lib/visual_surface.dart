import 'package:flutter/material.dart';

import 'visual_transport.dart';

/// Primary display preview shared by Snapshot and Live. No image is stored.
class VisualSurface extends StatefulWidget {
  const VisualSurface({
    super.key,
    required this.height,
    required this.frame,
    required this.live,
    required this.busy,
    required this.error,
    required this.onRefresh,
    required this.onTap,
    required this.onClick,
    required this.onMove,
    required this.onScroll,
  });

  final double height;
  final ScreenFrame? frame;
  final bool live;
  final bool busy;
  final String? error;
  final VoidCallback onRefresh;
  final void Function(int x, int y, String button) onTap;
  final ValueChanged<String> onClick;
  final ValueChanged<Offset> onMove;
  final ValueChanged<int> onScroll;

  @override
  State<VisualSurface> createState() => _VisualSurfaceState();
}

class _VisualSurfaceState extends State<VisualSurface> {
  double _zoom = 1;
  double _startZoom = 1;
  Offset? _lastFocal;
  double _scrollRemainder = 0;
  // Screen preview and trackpad share the same relative cursor gesture.
  final Map<int, Offset> _fingers = {};
  bool _movedWithMultipleFingers = false;

  void _fingerDown(PointerDownEvent event) {
    if (_fingers.isEmpty) _movedWithMultipleFingers = false;
    _fingers[event.pointer] = event.localPosition;
    if (_fingers.length > 1) _movedWithMultipleFingers = true;
  }

  void _fingerMove(PointerMoveEvent event) {
    final previous = _fingers[event.pointer];
    if (previous == null) return;
    _fingers[event.pointer] = event.localPosition;
    if (_fingers.length != 1 || _movedWithMultipleFingers) return;
    final delta = event.localPosition - previous;
    if (delta.distanceSquared > 0) widget.onMove(delta);
  }

  void _fingerUp(PointerEvent event) {
    _fingers.remove(event.pointer);
  }

  void _tap(Offset local, Size size, String button) {
    final frame = widget.frame;
    if (frame == null) return;
    final coords = VisualGeometry.tap(local, size,
        imageWidth: frame.width, imageHeight: frame.height, zoom: _zoom);
    if (_movedWithMultipleFingers) return;
    if (coords != null) {
      widget.onTap(coords.$1, coords.$2, button);
    } else {
      // Letterboxed margins should still behave as a normal touchpad.
      widget.onClick(button);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(height: widget.height,
      child: LayoutBuilder(builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _fingerDown,
            onPointerMove: _fingerMove,
            onPointerUp: _fingerUp,
            onPointerCancel: _fingerUp,
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) =>
                _tap(details.localPosition, viewport, 'left'),
            onDoubleTapDown: (details) =>
                _tap(details.localPosition, viewport, 'double'),
            onLongPressStart: (details) =>
                _tap(details.localPosition, viewport, 'right'),
            onScaleStart: (details) {
              _startZoom = _zoom;
              _lastFocal = details.localFocalPoint;
            },
            onScaleUpdate: (details) {
              if (details.pointerCount < 2) return;
              final previous = _lastFocal;
              _lastFocal = details.localFocalPoint;
              if ((details.scale - 1).abs() >= 0.025 ||
                  _startZoom != 1) {
                setState(() {
                  _zoom = (_startZoom * details.scale).clamp(1.0, 4.0);
                });
              } else if (previous != null) {
                _scrollRemainder +=
                    (details.localFocalPoint.dy - previous.dy) / 16.0;
                final ticks = _scrollRemainder.truncate().clamp(-8, 8);
                if (ticks != 0) {
                  _scrollRemainder -= ticks;
                  widget.onScroll(ticks);
                }
              }
            },
            onScaleEnd: (_) {
              _lastFocal = null;
              _scrollRemainder = 0;
            },
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Stack(fit: StackFit.expand, children: [
                if (widget.frame != null)
                  Center(child: Transform.scale(
                    scale: _zoom,
                    child: Image.memory(widget.frame!.jpeg,
                      gaplessPlayback: true, fit: BoxFit.contain,
                      filterQuality: FilterQuality.low,
                    ),
                  ))
                else
                  Center(child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(widget.error ??
                        (widget.live ? 'Starting live screen…' :
                            'Requesting screenshot…'),
                      textAlign: TextAlign.center),
                  )),
                if (widget.error != null && widget.frame != null)
                  Align(alignment: Alignment.bottomCenter,
                    child: ColoredBox(color: Colors.black87,
                      child: Padding(padding: const EdgeInsets.all(6),
                        child: Text(widget.error!, textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white,
                            fontSize: 11))))),
                Positioned(right: 8, top: 8, child: Row(
                  mainAxisSize: MainAxisSize.min, children: [
                    if (_zoom > 1)
                      IconButton.filledTonal(
                        key: const ValueKey('visual-reset-zoom'),
                        tooltip: 'Reset zoom',
                        onPressed: () => setState(() => _zoom = 1),
                        icon: const Icon(Icons.center_focus_strong),
                      ),
                    if (!widget.live)
                      IconButton.filledTonal(
                        key: const ValueKey('visual-refresh-now'),
                        tooltip: 'Refresh now',
                        onPressed: widget.busy ? null : widget.onRefresh,
                        icon: const Icon(Icons.refresh),
                      ),
                  ],
                )),
                if (widget.busy)
                  const Positioned(left: 10, top: 10,
                    child: SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))),
                Positioned(left: 8, bottom: 8,
                  child: IgnorePointer(child: Text(
                    widget.live ? 'LIVE • local only' : 'SNAPSHOT • 15s',
                    style: const TextStyle(fontSize: 10,
                      color: Colors.white,
                      shadows: [Shadow(blurRadius: 3,
                        color: Colors.black)])))),
              ]),
            ),
          ),
          ),
        );
      }),
    );
  }
}
