/// Planned shared visual-control modes for v0.7.
/// The corresponding OS capture and authenticated streaming transports
/// will be enabled only when implemented and granted screen permissions.
enum VisualMode { trackpad, snapshot, live }

extension VisualModeLabel on VisualMode {
  String get label => switch (this) {
    VisualMode.trackpad => 'Trackpad',
    VisualMode.snapshot => 'Snapshot',
    VisualMode.live => 'Live',
  };
}

class VisualModePolicy {
  const VisualModePolicy._();

  static const snapshotInterval = Duration(seconds: 15);

  /// Some running agents have a working capture endpoint even when the
  /// best-effort /api/info feature advertisement is absent or stale. Let
  /// macOS/Windows try the authenticated endpoint and show any real error.
  /// Ubuntu stays disabled until its capture backend advertises support.
  static bool canRequestCapture({
    required bool advertised,
    required String? platform,
  }) => advertised || platform == 'darwin' || platform == 'windows';

  static String normalize(String? value) =>
      const {'trackpad', 'snapshot', 'live'}.contains(value)
          ? value! : 'trackpad';
}
